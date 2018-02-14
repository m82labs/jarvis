# -*- coding: utf-8 -*-
from jira import JIRA
from dateutil import parser
import sys
import json
import re
import os
import traceback

plugin_type = 'passive'
purpose = '*JIRA*: I listen for jira issue keys and display information about the given issue.'

def run(message,user,email):
    # Define the command pattern to look for
    command_pattern = "([A-Z]{1,7}-[\d]{2,6})\w+"

    # Create out final results dictionary
    result = dict()
    result['matched'] = 0

    # Load our config file data, return and print error on error
    try:
        server_url = os.environ["JIRA_URL"]
        username = os.environ["JIRA_USER"]
        password = os.environ["JIRA_PASSWORD"]
    except IOError as e:
        print(e)
        return result

    # Set the JIRA client options
    options = {
        'server':server_url
    }

    # Do a regex on each token of the message
    for m in [m.lower() for m in message]:
        sp = re.compile(command_pattern, re.IGNORECASE)
        sp_m = sp.match(m)

        # If a match is found, look up data from JIRA
        if sp_m:
            try:
                # Create a JIRA client
                jc = JIRA(options,basic_auth=(username,password))

                # Get the matched issue key and pull in details from JIRA
                issue_key = sp_m.group()
                issue = jc.issue(issue_key)

                try:
                    if len(issue.fields.description) >= 253:
                        description = str(issue.fields.description)[0:256] + '...'
                    else:
                        description = str(issue.fields.description)
                except:
                    description = 'N/A'

                # Construct our response message and store in the result dict.
                result['output']  = '*JIRA Issue: *' + server_url + '/browse/' + issue_key + '\r```'
                result['output']  += 'Summary:  ' + str(issue.fields.summary) + '\r'
                result['output']  += 'Description:\r' + description + '\r\r'
                result['output']  += 'Status:   ' + str(issue.fields.status) + '\r'
                result['output']  += 'Assignee: ' + str(issue.fields.assignee) + '\r'
                result['output']  += 'Reporter: ' + str(issue.fields.reporter) + '\r'
                result['output']  += 'Created:  ' + parser.parse(issue.fields.created).strftime('%Y-%m-%d %I:%M %p')  + '\r'
                result['output']  += 'Updated:  ' + parser.parse(issue.fields.updated).strftime('%Y-%m-%d %I:%M %p') + '```'

                result['matched'] = 1
            except:
                t,v,tb = sys.exc_info()
                print(v)
                traceback.print_exc()
                result['matched'] = 0
    return result
