# install python virtual environment
sudo apt update
sudo apt install -y python3 python3-pip
sudo apt install -y python3-venv

sudo tee /usr/local/bin/.env > /dev/null <<'EOF'
# Twilio Configuration
TWILIO_ACCOUNT_SID="***********"
TWILIO_AUTH_TOKEN="*****************"
TWILIO_PHONE_NUMBER="+123456789"
PRIMARY_SMS_NUMBER="+123456789"
SECONDARY_SMS_NUMBER="+123456789"
# Gmail SMTP Configuration - app password setup required
GMAIL_USERNAME="******@gmail.com"
GMAIL_PASSWORD="**** **** **** ****"
EMAIL_RECIPIENTS="*****@gmail.com"
EOF

sudo tee /usr/local/bin/requirements-notify.txt > /dev/null <<'EOF'
python-dotenv>=1.0.0
twilio>=8.0.0
EOF

sudo tee /usr/local/bin/notify.py > /dev/null <<'EOF'
#!/usr/bin/env python3
"""
NOTIFY.PY - Notification System
===============================
Send notifications via email and SMS (Twilio).

USAGE EXAMPLES:
---------------
# Basic email notification (default)
python notify.py "Hello world"

# Email with custom subject
python notify.py "System alert" --subject "🚨 ALERT"

# Email only
python notify.py "Email only message" --email-only

# SMS only (to primary number from environment)
python notify.py "SMS alert" --sms-only

# SMS only to specific number
python notify.py "Emergency!" --sms-only --sms-primary +1234567890

# Email + primary SMS
python notify.py "Important update" --sms-primary

# Email + both SMS numbers
python notify.py "Broadcast message" --sms-primary --sms-secondary

# Read message from file
python notify.py -f alert_message.txt --subject "Daily Report"

# Test notification (predefined format)
python notify.py --test

# Quiet mode ... no console output
python notify.py "Backup complete" --quiet

# Multiple options combined
python notify.py "Server down!" --subject "URGENT" --email-only --quiet

ENVIRONMENT VARIABLES:
----------------------
Required in .env file or environment:
- GMAIL_USERNAME: Your Gmail address
- GMAIL_PASSWORD: Gmail app password
- EMAIL_RECIPIENTS: Comma-separated email addresses
- TWILIO_ACCOUNT_SID: Twilio account SID
- TWILIO_AUTH_TOKEN: Twilio auth token
- TWILIO_PHONE_NUMBER: Twilio phone number

Optional:
- PRIMARY_SMS_NUMBER: Default primary SMS recipient
- SECONDARY_SMS_NUMBER: Default secondary SMS recipient
- SMTP_SERVER: SMTP server (default: smtp.gmail.com)
- SMTP_PORT: SMTP port (default: 587)
"""

import asyncio
import os
import json
import time
import sys
import argparse

# notifications - environment variables from .env file
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from typing import Dict, List, Optional
from twilio.rest import Client
from twilio.base.exceptions import TwilioRestException

# Load environment variables from .env file
from dotenv import load_dotenv
load_dotenv()

# ================================================================
# LOGGING
# ================================================================
def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] [RigCloud] {msg}", flush=True)

#=================================================================
# Notifications
#=================================================================
class NotificationService:
    def __init__(self):
        # Twilio Configuration
        self.twilio_account_sid = os.getenv("TWILIO_ACCOUNT_SID")
        self.twilio_auth_token = os.getenv("TWILIO_AUTH_TOKEN")
        self.twilio_phone_number = os.getenv("TWILIO_PHONE_NUMBER")
        
        # Gmail SMTP Configuration
        self.smtp_server = os.getenv("SMTP_SERVER", "smtp.gmail.com")
        self.smtp_port = int(os.getenv("SMTP_PORT", 587))
        self.smtp_username = os.getenv("GMAIL_USERNAME")
        self.smtp_password = os.getenv("GMAIL_PASSWORD")
        self.email_recipients = os.getenv("EMAIL_RECIPIENTS", "").split(",")
        
        # Initialize Twilio client if credentials are available
        self.twilio_client = None
        if self.twilio_account_sid and self.twilio_auth_token:
            self.twilio_client = Client(self.twilio_account_sid, self.twilio_auth_token)
    
    def send_email(self, subject: str, body: str, html_body: Optional[str] = None) -> bool:
        """Send email notification via SMTP"""
        try:
            if not all([self.smtp_username, self.smtp_password, self.email_recipients]):
                log("Email configuration incomplete")
                return False
            
            # Create message
            msg = MIMEMultipart('alternative')
            msg['Subject'] = subject
            msg['From'] = self.smtp_username
            msg['To'] = ", ".join(self.email_recipients)
            
            # Attach plain text version
            text_part = MIMEText(body, 'plain')
            msg.attach(text_part)
            
            # Attach HTML version if provided
            if html_body:
                html_part = MIMEText(html_body, 'html')
                msg.attach(html_part)
            
            # Connect to SMTP server and send
            with smtplib.SMTP(self.smtp_server, self.smtp_port) as server:
                server.starttls()
                server.login(self.smtp_username, self.smtp_password)
                server.send_message(msg)
            
            log(f"Email sent successfully to {self.email_recipients}")
            return True
            
        except Exception as e:
            log(f"Failed to send email: {e}")
            return False
    
    def send_sms(self, message: str, to_number: str, from_number: Optional[str] = None) -> bool:
        """Send SMS notification via Twilio (primary recipient)"""
        return self._send_twilio_sms(message, to_number, from_number, "primary")
    
    def send_sms_secondary(self, message: str, to_number: str, from_number: Optional[str] = None) -> bool:
        """Send SMS notification via Twilio (secondary recipient)"""
        return self._send_twilio_sms(message, to_number, from_number, "secondary")
    
    def _send_twilio_sms(self, message: str, to_number: str, 
                         from_number: Optional[str], notification_type: str) -> bool:
        """Internal method to send Twilio SMS"""
        try:
            if not self.twilio_client:
                log(f"Twilio client not initialized for {notification_type} SMS")
                return False
            
            # Use provided from_number or default from configuration
            from_num = from_number or self.twilio_phone_number
            
            if not from_num or not to_number:
                log(f"Missing phone numbers for {notification_type} SMS")
                return False
            
            # Send SMS
            sms = self.twilio_client.messages.create(
                body=message,
                from_=from_num,
                to=to_number
            )
            
            log(f"{notification_type.capitalize()} SMS sent to {to_number}, SID: {sms.sid}")
            return True
            
        except TwilioRestException as e:
            log(f"Twilio API error for {notification_type} SMS: {e}")
            return False
        except Exception as e:
            log(f"Failed to send {notification_type} SMS: {e}")
            return False
    
    def send_notification(self, 
                         message: str, 
                         subject: Optional[str] = None,
                         email: bool = True,
                         sms_primary: bool = False,
                         sms_secondary: bool = False,
                         sms_primary_number: Optional[str] = None,
                         sms_secondary_number: Optional[str] = None) -> Dict[str, bool]:
        """
        Send comprehensive notification through multiple channels
        
        Returns a dictionary showing which notifications were successful
        """
        results = {
            "email_sent": False,
            "sms_primary_sent": False,
            "sms_secondary_sent": False
        }
        
        # Send email if requested
        if email:
            email_subject = subject or "Notification"
            results["email_sent"] = self.send_email(email_subject, message)
        
        # Send primary SMS if requested
        if sms_primary and sms_primary_number:
            results["sms_primary_sent"] = self.send_sms(message, sms_primary_number)
        
        # Send secondary SMS if requested
        if sms_secondary and sms_secondary_number:
            results["sms_secondary_sent"] = self.send_sms_secondary(message, sms_secondary_number)
        
        return results

# Initialize the notification service
notification_service = NotificationService()

#=================================================================
# Command Line Interface
#=================================================================
def parse_arguments():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(
        description='Send notifications via email and/or SMS',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    # Message content (either as argument or from file)
    content_group = parser.add_mutually_exclusive_group(required=True)
    content_group.add_argument(
        'message',
        nargs='?',
        help='Message content to send'
    )
    content_group.add_argument(
        '-f', '--file',
        help='Read message content from a file'
    )
    content_group.add_argument(
        '-t', '--test',
        action='store_true',
        help='Send a test notification'
    )
    
    # Notification options
    parser.add_argument(
        '-s', '--subject',
        default='Notification',
        help='Email subject line (default: "Notification")'
    )
    
    parser.add_argument(
        '--sms-primary',
        metavar='PHONE_NUMBER',
        help='Send SMS to primary number (overrides env var PRIMARY_SMS_NUMBER)'
    )
    
    parser.add_argument(
        '--sms-secondary',
        metavar='PHONE_NUMBER',
        help='Send SMS to secondary number (overrides env var SECONDARY_SMS_NUMBER)'
    )
    
    # Channel selection
    channel_group = parser.add_argument_group('Channel selection')
    channel_group.add_argument(
        '--email-only',
        action='store_true',
        help='Send email only (no SMS)'
    )
    channel_group.add_argument(
        '--sms-only',
        action='store_true',
        help='Send SMS only (no email)'
    )
    
    # Additional options
    parser.add_argument(
        '--quiet',
        action='store_true',
        help='Suppress non-essential output'
    )
    
    return parser.parse_args()

def read_message_from_file(file_path: str) -> str:
    """Read message content from a file"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            return f.read().strip()
    except FileNotFoundError:
        log(f"Error: File '{file_path}' not found")
        sys.exit(1)
    except Exception as e:
        log(f"Error reading file: {e}")
        sys.exit(1)

def create_test_message() -> str:
    """Create a test notification message"""
    return f"""🔔 Notification Service Test

Test message sent at: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}
Service: RigCloud Notification System
Status: Operational
Environment: {os.getenv('ENVIRONMENT', 'Development')}

This is a test notification to verify that your notification system is working correctly."""

def send_notification_from_cli():
    """Main function to handle CLI notification sending"""
    args = parse_arguments()
    
    # Determine message content
    if args.test:
        message = create_test_message()
        subject = "✅ Notification Service Test"
    elif args.file:
        message = read_message_from_file(args.file)
        subject = args.subject
    else:
        message = args.message
        subject = args.subject
    
    # Only log if not quiet mode
    if not args.quiet:
        log(f"Sending notification: {subject}")
        if len(message) > 100:
            log(f"Message preview: {message[:100]}...")
        else:
            log(f"Message: {message}")
    
    # Get phone numbers (use provided or from env)
    sms_primary_number = args.sms_primary or os.getenv("PRIMARY_SMS_NUMBER")
    sms_secondary_number = args.sms_secondary or os.getenv("SECONDARY_SMS_NUMBER")
    
    # FIXED: Determine which channels to use
    # If --email-only is specified, only send email
    if args.email_only:
        send_email = True
        send_sms_primary = False
        send_sms_secondary = False
    
    # If --sms-only is specified, only send SMS (if numbers available)
    elif args.sms_only:
        send_email = False
        send_sms_primary = bool(sms_primary_number)
        send_sms_secondary = bool(sms_secondary_number)
    
    # DEFAULT: Send email by default, SMS only if explicitly requested
    else:
        send_email = True
        # Only send SMS if explicitly requested via command line
        send_sms_primary = bool(args.sms_primary)  # Only if --sms-primary flag used
        send_sms_secondary = bool(args.sms_secondary)  # Only if --sms-secondary flag used
    
    # Validate: If SMS is requested but no number is available
    if send_sms_primary and not sms_primary_number:
        if not args.quiet:
            log("⚠️ Warning: Primary SMS requested but no phone number available")
        send_sms_primary = False
    
    if send_sms_secondary and not sms_secondary_number:
        if not args.quiet:
            log("⚠️ Warning: Secondary SMS requested but no phone number available")
        send_sms_secondary = False
    
    # Send the notification
    results = notification_service.send_notification(
        message=message,
        subject=subject,
        email=send_email,
        sms_primary=send_sms_primary,
        sms_secondary=send_sms_secondary,
        sms_primary_number=sms_primary_number,
        sms_secondary_number=sms_secondary_number
    )
    
    # Only display results if not quiet mode
    if not args.quiet:
        log("="*50)
        log("NOTIFICATION RESULTS")
        log("="*50)
        
        if send_email:
            if results.get("email_sent"):
                recipients = notification_service.email_recipients if hasattr(notification_service, 'email_recipients') else "recipients"
                log(f"✅ Email: Sent successfully to {recipients}")
            else:
                log("❌ Email: Failed to send")
        else:
            log("➖ Email: Not requested")
        
        if send_sms_primary:
            if results.get("sms_primary_sent"):
                log(f"✅ Primary SMS: Sent to {sms_primary_number}")
            else:
                log(f"❌ Primary SMS: Failed to send to {sms_primary_number}")
        else:
            if sms_primary_number and not args.sms_only:
                log("➖ Primary SMS: Available but not requested (use --sms-primary)")
            else:
                log("➖ Primary SMS: Not available or not requested")
        
        if send_sms_secondary:
            if results.get("sms_secondary_sent"):
                log(f"✅ Secondary SMS: Sent to {sms_secondary_number}")
            else:
                log(f"❌ Secondary SMS: Failed to send to {sms_secondary_number}")
        else:
            if sms_secondary_number and not args.sms_only:
                log("➖ Secondary SMS: Available but not requested (use --sms-secondary)")
            else:
                log("➖ Secondary SMS: Not available or not requested")
        
        log("="*50)
    
    # Return appropriate exit code (ALWAYS do this, even in quiet mode)
    if any(results.values()):
        if not args.quiet:
            log("✅ Notification(s) sent successfully")
        sys.exit(0)  # Success if at least one notification was sent
    else:
        if not args.quiet:
            log("❌ No notifications were sent")
        sys.exit(1)  # Failure if no notifications were sent

#=================================================================
# Main entry point
#=================================================================
if __name__ == "__main__":
    send_notification_from_cli()
EOF
