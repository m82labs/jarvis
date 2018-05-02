import pymssql
import json
import re
import sys
import os

plugin_type = 'active'
purpose = '*Server Status*: Ask `Whats the status of server-102?` to get general SQL health information. You must specify the server using the standard CA format, or an IP address. Currently this plugin only gets data from SQL instances.'

def run(message,user,email):
    # Define our command pattern
    command_pattern = ["status"]

    # Define what a 'server' looks like
    if "SQL_REGEX" in os.environ:
        server_pattern = os.environ["SQL_REGEX"]
    else:
        server_pattern = "([a-z,0-9]{2,3}-.{3,9}-[0-9]{1,3})|([0-9]{0,2}\.[0-9]{0,2}\.[0-9]{0,2}\.[0-9]{0,2})\w+"

    # Define the match threshold
    current_match = 0
    match_needed = len(command_pattern) + 1

    # Set up the result dictionary
    result = dict()
    result['matched'] = 0

    # Load our SQL script
    try:
        sqlCmd = open('plugins/sql_status/sql_script.sql').read()
    except IOError as e:
        print(e)
        return result

    # Load our config file
    try:
        user = os.environ["DB_USERNAME"]
        password = os.environ["DB_PASSWORD"]
    except IOError as e:
        print(e)
        return result

    # Loop through the message and find command pattern matches
    for c in command_pattern:
        if c in [m.lower() for m in message]:
            current_match += 1

    if current_match > 0:
        # If we have matched the command pattern, we now check the server pattern
        for msg in [ m.lower() for m in message]:
            # If the message contains a link, split it apart
            if msg.count("|") == 1:
                m = msg.split('|')[1]
            else:
                m = msg

            # Do a regex match on the server pattern
            sp = re.compile(server_pattern, re.IGNORECASE)
            sp_m = sp.match(m)
            if sp_m:
                    #                server = sp_m.group()
                server = m
                current_match += 1

    # Assuming we have enough matches, retrieve data from SQL
    if current_match >= match_needed:
        result['matched'] = 1

        # Try to execute our query, if it fails, return the failure to Slack
        try:
            with pymssql.connect(server,user,password,'master',login_timeout=15,timeout=30,appname="Jarvis",) as conn:
                with conn.cursor(as_dict=True) as cursor:
                    cursor.execute(sqlCmd)
                    for row in cursor:
                            result['output'] = '*Server Status: ' + server + '* ```' + row['result'] + '```'
        except:
            result['output'] = 'Sorry, I ran into an error trying to get the status of that server: ```' + str(sys.exc_info()[1]) + '```'

    return result
