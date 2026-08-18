## * Only email notify tested so far *

** updated service to use .venv virtual environment, uninstall not needed requirements from system **

Ubuntu 24.04:

sudo python3 -m pip uninstall -y aiomqtt typing_extensions paho-mqtt --break-system-packages

Ubuntu 22.04:

sudo python3 -m pip uninstall -y aiomqtt typing_extensions paho-mqtt
