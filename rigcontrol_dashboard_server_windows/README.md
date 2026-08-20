[Get started](../README.md#get-started)

1. best compadability install python v3.11.x ... [python-3.11.9-amd64.exe](https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe), check add to path...

![python-install.png](../images/Screenshot-python-install.png)

2. install x64 version of mqtt broker from https://mosquitto.org/download/

3. setup password,config, and data folder see [mosquitto-setup.txt](mosquitto-setup.txt)

![mqtt-install](../images/Screenshot-mqtt-install.png)

![mqtt-test](../images/Screenshot-mqtt-test.png)

4. create a folder to download and keep your server files

5. download extract [static.zip](../static) to create static folder layout

![static-zip](../images/Screenshot-static-zip.png)

6. download/replace latest [index.html](../static/index.html), [landing.html](../static/landing.html), [app.js](../static/js/app.js), [app.css](../static/css/app.css) from static locations

7. download the other needed files: [.env.example](.env.example), [requirements.txt](requirements.txt), [rigcontrol_dashboard_server.py](rigcontrol_dashboard_server.py), [rigcontrol_config.json](rigcontrol_config.json), 'run.bat'

(.env.example rename back to .env once downloaded)

8. set server settings in the .env file, 'MQTT_USER, MQTT_PASS', gmail, gmail app password for email offline notifications, sms

[google app password](https://myaccount.google.com/apppasswords)

9. 'run.bat' create and activate virtual environment with requirements and start server

![run-bat](../images/Screenshot-run-bat.png)

-- to start on boot create a basic task in windows task scheduler to start 'run.bat' when user logs on with highest privelage checked --

-- [accessKeys.csv.example](accessKeys.csv.example) (rename to accessKeys.csv) is only if you plan on using a amazon connection

-- if not running on windows or dont want mosquitto to start with the server:

remove the mosquitto start functions section near the top and if statement near bottom of .py
