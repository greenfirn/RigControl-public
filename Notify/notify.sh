tee notify.sh > /dev/null <<'EOF'
#!/bin/bash

# Notify.sh - Ubuntu/Linux version
# Usage: ./notify.sh [arguments]

set -e  # Exit on error

echo "Checking and setting up environment..."

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check for virtual environment
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
    
    # Activate virtual environment
    source .venv/bin/activate
    
    # Only install requirements when creating fresh virtual environment
    # Check for requirements file in script directory first, then /usr/local/bin
    REQUIREMENTS_FILE="requirements-notify.txt"
    if [ -f "$REQUIREMENTS_FILE" ]; then
        echo "Found local requirements file..."
    elif [ -f "/usr/local/bin/requirements-notify.txt" ]; then
        echo "Found system requirements file..."
        REQUIREMENTS_FILE="/usr/local/bin/requirements-notify.txt"
    else
        echo "Warning: No requirements-notify.txt file found"
        echo "Please ensure you have one in either:"
        echo "  - $SCRIPT_DIR/requirements-notify.txt"
        echo "  - /usr/local/bin/requirements-notify.txt"
    fi
    
    # Install requirements if file exists
    if [ -f "$REQUIREMENTS_FILE" ]; then
        echo "Installing dependencies from $REQUIREMENTS_FILE..."
        python -m pip install --upgrade pip
        pip install -r "$REQUIREMENTS_FILE"
        echo "Dependencies installed successfully."
    fi
else
    echo "Virtual environment already exists - skipping requirements check/install."
    # Just activate existing environment
    source .venv/bin/activate
fi

NOTIFY_SCRIPT="/usr/local/bin/notify.py"
if [ -f "$NOTIFY_SCRIPT" ]; then
    echo "Using system notify.py from /usr/local/bin..."
else
    echo "Error: notify.py not found at /usr/local/bin/notify.py!"
    exit 1
fi

# Run the notification script
echo "Starting Notify..."
echo "Command: python $NOTIFY_SCRIPT $@"
python "$NOTIFY_SCRIPT" "$@"

echo ""
echo "Notify complete."

exit 0
EOF

# Make executable
chmod +x notify.sh

# Test message
./notify.sh "Email only message"
