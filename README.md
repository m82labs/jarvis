# Jarvis - A Slackbot for Operations

Jarvis is a Slack bot that can interact with MS SQL Server, Pagerduty, and JIRA.

## Connecting to Slack

In order to connect to Slack you have to first configure a bot integration. This will provide you with an API token. This token, as well as the bot name, must be passed in via envrionment variables SLACK_TOKEN and SLACK_BOT.

```
docker run \
  -e 'SLACK_TOKEN=xxxx-00000000000-000000000000000000000000' \
  -e 'SLACK_BOT=jarvis' \
  -d m82labs/jarvis
```

## Limiting Plugins

If you only want to run specific plugins, you can list them in the PLUGINS environment variable. Current available plugins are: sql_status, jira, and pagerduty.
```
 docker run \
  -e 'SLACK_TOKEN=xxxx-00000000000-000000000000000000000000' \
  -e 'SLACK_BOT=jarvis' \
  -e 'PLUGINS=sql_status jira'  \
  -d m82labs/jarvis
```

## MS SQL Server

To connect to SQL Server you must first create a user on each instance you will be connecting to. The user will require VIEW SERVER STATE permissions. When running the container, the DB_USERNAME and DB_PASSWORD environment variables must be provided.

Jarvis uses REGEX to determine which server you are trying to get the status of. By default it will match servers with a naming scheme of: AA-AAAA-###, or a standard IP address. If you have a special naming scheme you use, pass in a regex that matches it via the SQL_REGEX environment variable.
```
docker run \
  -e 'SLACK_TOKEN=xxxx-00000000000-000000000000000000000000' \
  -e 'SLACK_BOT=jarvis' \
  -e 'DB_USERNAME=jarvis' \
  -e 'DB_PASSWORD=MyStrongPassword001@@' \
  -d m82labs/jarvis
```

## JIRA

JIRA requires a username and password, as well as the base URL for the JIRA API.
```
docker run \
  -e 'SLACK_TOKEN=xxxx-00000000000-000000000000000000000000' \
  -e 'SLACK_BOT=jarvis' \
  -e 'JIRA_USER=jarvis' \
  -e 'JIRA_PASSWORD=MyStrongPassword001@@' \
  -e 'JIRA_URL=https://jira.mydomain.com' \
  -d m82labs/jarvis
```

## PagerDuty

Jarvis has several functions related to PagerDuty including assigning the pager to the user, seeing who is on call, and seeing when the user is on call next. You must supply a PagerDuty API key to use this plugin.

```
docker run \
  -e 'SLACK_TOKEN=xxxx-00000000000-000000000000000000000000' \
  -e 'SLACK_BOT=jarvis' \
  -e 'PD_API_KEY=xxxxxxxx` \
  -d m82labs/jarvis
```
