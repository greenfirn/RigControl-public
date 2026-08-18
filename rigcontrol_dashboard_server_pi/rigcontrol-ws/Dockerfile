FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Just copy the single file
COPY rigcontrol_dashboard_server.py ./rigcontrol_dashboard_server.py
COPY accessKeys.csv .
COPY static ./static

CMD ["python", "rigcontrol_dashboard_server.py"]
