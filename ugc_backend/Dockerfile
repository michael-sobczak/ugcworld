FROM python:3.12-slim

WORKDIR /app

# Install dependencies first for better caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create data directory for SQLite and spell storage
RUN mkdir -p /app/data/spells

# Expose the default port
EXPOSE 5000

# Environment defaults
ENV HOST=0.0.0.0
ENV PORT=5000

# Run the raw WebSocket server (compatible with Godot WebSocketPeer)
CMD ["python", "app.py"]
