FROM docker.io/frolvlad/alpine-python3
RUN apk update
RUN apk --no-cache add git python3-dev freetds freetds-dev linux-headers g++
RUN mkdir -p /opt/jarvis/
ADD jarvis.py /opt/jarvis/
ADD pluginloader /opt/jarvis/pluginloader
ADD plugins /opt/jarvis/plugins
ADD tokenizer.py /opt/jarvis

# Python deps
RUN pip3 --no-cache install Cython slackclient jira python-dateutil
RUN pip3 --no-cache install git+https://github.com/pymssql/pymssql.git

# Remove stuff we no longer need
RUN apk del git linux-headers g++
RUN pip3 uninstall -y Cython
# Change to the jarvis directory and start
WORKDIR /opt/jarvis
CMD python3 -u jarvis.py
