from dateutil import tz
import requests
import datetime
import json
import sys
import os

plugin_type = 'active'
purpose = '*PagerDuty*: Ask `Who is on call?` to see who is currently on-call, `When am I on call next?` to see when your next shift starts, or tell jarvis to `give me the pager` to cover the pager for the current person tht is on-call.'
database = 'pagerduty.db'

def run(message, name, email):
    # Set command pattern to match on
    command_patterns = [["who","whos","on","call"],["when","on","i","call","next"],["give","pager","me"]]

    # Create our result dictionary and initial values
    result = dict()
    result['matched'] = 0
    result['output'] = ''

    # Load config data
    try:
        # Set up out API call headers
        headers = {"Authorization": "Token token=" + os.environ["PD_API_KEY"], "Accept" : "application/vnd.pagerduty+json;version=2"}
    except IOError as e:
        print(e)
        return result

    match = 0

    # Match our command pattern to the message text
    for i in range(0,len(command_patterns)):
        match_needed = len(command_patterns[i])/2
        current_match = 0

        for c in command_patterns[i]:
            for m in [m.lower() for m in message]:
                # Replaces simplify matching (on-call -> on call,etc.)
                if c == m.replace('\'','').replace('-',''):
                    current_match += 1

        # If we have made a full match, get on-call data
        if current_match > match_needed:
            result['matched'] = 1
            match = i
            from_zone = tz.tzutc()
            to_zone = tz.tzlocal()

    if match == 0:
        result['output'] = "The following people are currently on-call:\r"

        # Try a web request to PagerDuty
        try:
            r = requests.get('https://api.pagerduty.com/oncalls?limit=100', headers=headers)
            data = r.json()['oncalls']
        except:
            e = sys.exc_info()[1]
            print(e)
            return result

        # If the data was succesfully retrieved, append to the response message and return
        for record in data:
            curr_team = record['escalation_policy']['summary']

            # If the on-call 'start' time is null, it is a scheduled on-call as opposed to a user that
            # is "always" on-call, IE, not in the rotation
            if record['start'] != None:
                result['output'] += "*" + record['user']['summary'] + "* (" + curr_team + ")\r"
    elif match == 1:
        result['output'] = "Your next on-call shift starts: "

        # Try a web request to PagerDuty
        try:
            r = requests.get('https://api.pagerduty.com/users?query='+email, headers=headers)
            userid = r.json()['users'][0]['id']
        except:
            e = sys.exc_info()[1]
            print(e)
            return result

        try:
            start_date = datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')
            end_date = (datetime.datetime.now() + datetime.timedelta(days=14)).strftime('%Y-%m-%d')

            r = requests.get('https://api.pagerduty.com/oncalls?user_ids%5B%5D='+userid+'&since=' + start_date + '&until=' + end_date + '&earliest=false', headers=headers)
            oncall_data = r.json()['oncalls']
            oncall = [ oc for oc in oncall_data if oc['start'] and datetime.datetime.strptime(oc['start'],'%Y-%m-%dT%H:%M:%SZ') > datetime.datetime.utcnow()][0]
            oncall_start_utc = datetime.datetime.strptime(oncall['start'],'%Y-%m-%dT%H:%M:%SZ')
            oncall_start_utc = oncall_start_utc.replace(tzinfo=from_zone)
            oncall_start_local = oncall_start_utc.astimezone(to_zone)
            result['output'] += "{}".format(oncall_start_local.strftime('%Y-%m-%d %H:%M %Z (%z from UTC)'))
        except:
            e = sys.exc_info()[1]
            print(e)
            return result
    elif match == 2:
        # Get the current team of the user requesting the pager
        # Get the user ID
        try:
            r = requests.get('https://api.pagerduty.com/users?query='+email, headers=headers)
            userid = r.json()['users'][0]['id']
        except:
            e = sys.exc_info()[1]
            print(e)
            return result

        # Get the escalation policy
        try:
            r = requests.get('https://api.pagerduty.com/escalation_policies?user_ids%5B%5D='+userid, headers=headers)
            escalations = r.json()['escalation_policies'][0]

            # Find the escalation policy for the schedule
            for er in escalations['escalation_rules']:
                for et in er['targets']:
                    if et['type'] == 'schedule_reference':
                        schedule = et['id']
        except:
            e = sys.exc_info()[1]
            print(e)
            return result

        # Get the current on-call for the users schedule
        try:
            r = requests.get('https://api.pagerduty.com/oncalls?schedule_ids%5B%5D='+schedule, headers=headers)
            end_date = r.json()['oncalls'][0]['end']
        except:
            e = sys.exc_info()[1]
            print(e)
            return result

        # Schedule the override
        start_date = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        override_payload = { 'override' : { 'start' : start_date, 'end' : end_date,'user' : { 'id' : userid ,'type' : 'user_reference'}}}

        try:
            headers = {"Authorization": "Token token=" + os.environ["PD_API_KEY"],"Accept": "application/vnd.pagerduty+json;version=2", "content-type": "application/json"}
            r = requests.post('https://api.pagerduty.com/schedules/'+schedule+'/overrides', headers=headers, data=json.dumps(override_payload))
            override_start = datetime.datetime.strptime(start_date,'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=from_zone).astimezone(to_zone)
            override_end = datetime.datetime.strptime(end_date,'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=from_zone).astimezone(to_zone)
            result['output'] = "Scheduling you for an override: \nFrom: {}\nTo: {}".format(override_start.strftime('%Y-%m-%d %H:%M %Z (%z from UTC)'),override_end.strftime('%Y-%m-%d %H:%M %Z (%z from UTC)'))
        except:
            e = sys.exc_info()[1]
            print(e)
            return result
    return result
