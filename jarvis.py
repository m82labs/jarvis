#! /usr/bin/env python
"""
Program: Jarvis is a general purpose, extensible, Slack Bot.
Author: Mark Wilkinson
Date: 2016/02/23
Notes: Jarvis supports a simple plugin framework and can handle
multiple concurrent conversations.

"""
import sys
import os
import pluginloader
import json
import requests
import time
import sqlite3 as sql
import tokenizer
import threading
from slackclient import SlackClient

# Slack stuff
try:
    token = os.environ["SLACK_TOKEN"]
    bot_name = os.environ["SLACK_BOT"]
except:
    print("Environment variables not set.")
    sys.exit(-1)

# User Data
user_data = sql.connect('userdata.db')
schema = """
CREATE TABLE IF NOT EXISTS SlackUsers (
    SlackUserName TEXT,
    EmailAddress TEXT
);
"""
cur = user_data.cursor()
cur.execute(schema)
user_data.close

get_user = """
SELECT  EmailAddress
FROM    SlackUsers
WHERE   SlackUserName = ?;
"""

put_user = """
INSERT INTO SlackUsers VALUES( ?, ?);
"""


# Helper function to get user data
def get_user_details(username,client):
    try:
        data = sql.connect('userdata.db')
        print("Getting details for: " + username)
        cur = data.cursor()
        cur.execute(get_user,(username,))
        user = cur.fetchone()

        if user:
            return user[0]

        userlist = client.api_call("users.list")

        for member in userlist['members']:
            if member['id'] == username:
                user_email = member['profile']['email']

        cur.execute(put_user,(username,user_email))
        data.commit()
        data.close()
        return user_email
    except:
        return None
    finally:
        if data:
            data.close()


# Main function that does the heavy lifting
def process_message(channel,user,message_text,message_type,client):
    """Passes messages to the installed plugins, also prints help"""
    print("Getting " + message_type + " plugins.")

    # Set up some initial variable values
    result = {"matched":0}
    response = "<@" + user + ">: "
    email = get_user_details(user,client)

    # Simple check to see if the message was direct, and was asking for help
    # If it was, set the is_help flag, which tells jarvis to print plugin help
    if message_text[len(message_text)-1] == 'help' and message_type == 'active':
        is_help = 1
        result['matched'] = 1
        response += "*Here is a list of my current capabilities:*"
    else:
        is_help = 0

    # Loop through all of our plugins
    if "PLUGINS" in os.environ:
        plugins = os.environ["PLUGINS"]
    else:
        plugins = "sql_status jira pagerduty"

    for p in [ p for p in pluginloader.getPlugins() if p["name"] in plugins]:
        print( "Processing plugin: " + p["name"])
        # Load the plugin
        plugin = pluginloader.loadPlugin(p)

        # If we are printing help only, append the purpose of each plugin to
        # the final response text
        if is_help == 1:
            response += "\r\r" + plugin.purpose
            continue

        # Run the plugin if we aren't just looking for help
        if plugin.plugin_type == message_type and is_help == 0:
            result = plugin.run(message_text, user, email)

        # If the plugin returned a match, meaning the command text for the plugin
        # matched the message text, get the output of the plugin and send a
        # response back to Slack
        if result['matched'] == 1:
            response += result['output']

            if 'direct' in result:
                channel = "@" + user

            if 'file' in result:
                # Upload and attach a file
                try:
                    res = client.api_call("files.upload",channels=channel,filename='Attachment',file=open(result['file'],'rb'),initial_comment=response)
                except Exception as e:
                    print(e)
                    return
                finally:
                    os.remove(result['file'])
            break

    # If a match was not made, BUT, it was an active message to Jarvis, display a joke
    # Otherwise, return the response message
    if result['matched'] != 1:
        if message_type == 'active':
            # Get a quote
            # http://quotes.stormconsultancy.co.uk/random.json
            # http://api.icndb.com/jokes/random
            r = requests.get('http://api.icndb.com/jokes/random')
            response = "Sorry, I don't understand what you are trying to do, but here's a quote to hold you over:\n"
            response += ">{}".format(r.json()['value']['joke'].encode('utf-8'))
            client.rtm_send_message(channel, response)
    else:
        client.rtm_send_message(channel,response)

# Main program loop
def main():
    # Create the slack client
    sc = SlackClient(token)

    # Get our bot ID
    userlist = sc.api_call("users.list")
    for member in userlist['members']:
        if member['name'] == bot_name:
            bot_user = member['id']
            print(bot_user)

    if sc.rtm_connect():
        # Start the main program loop
        while True:
            # Get the latest messages
            # sc.rtm_connect()
            messages = sc.rtm_read()

            if messages:
                for message in messages:
                    # Only care about messages from users
                    if 'text' in message.keys() and 'user' in message.keys():
                        # Break out and continue if the user that sent the message is the bot itself
                        if message['user'] == bot_user:
                            continue

                        # Tokenize the message text
                        # We replace '/' with ' ' to help tokenization of URLs
                        message_a = tokenizer.tokenize(message['text'].replace('/',' ').replace("<@{}>".format(bot_user),''))

                        # Determine if the message was sent directly to the bot or not
                        if bot_user in message['text']:
                            message_type = 'active'
                        else:
                            message_type = 'passive'

                        # Start a new process to process our message
                        t = threading.Thread( target=process_message, args=(message['channel'],message['user'],message_a,message_type,sc))
                        t.start()
            # Sleep for small amount of time to control CPU usage
            time.sleep(0.25)
            messages = None
    else:
        e = sys.exc_info()[0]
        print("Connection Failed, invalid token?",e)

if __name__=="__main__":
    main()
