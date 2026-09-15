import os
import mysql.connector
import asyncio
import nats
import json

db_host = os.getenv("DB_HOST", "sa-platform-mysql")
db_user = os.getenv("DB_USER", "user")
db_pass = os.getenv("DB_PASSWORD", "password123")
db_name = os.getenv("DB_NAME", "sa_p5")
nats_url = os.getenv("NATS_URL", "nats://sa-platform-nats:4222")

async def main():
    conn = mysql.connector.connect(host=db_host, user=db_user, password=db_pass, database=db_name)
    cursor = conn.cursor(dictionary=True)
    
    # Query summary
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS cron_logs (
        id INT AUTO_INCREMENT PRIMARY KEY,
        execution_time DATETIME,
        student_id VARCHAR(20)
    )
    """)
    cursor.execute("""
    SELECT DATE_FORMAT(execution_time, '%Y-%m-%d %H:00:00') as hour, COUNT(*) as count 
    FROM cron_logs 
    GROUP BY hour
    """)
    rows = cursor.fetchall()
    conn.close()
    
    if not rows:
        print("No data to publish")
        return
        
    nc = await nats.connect(nats_url)
    js = nc.jetstream()
    
    for row in rows:
        payload = json.dumps({"event": "HOURLY_SUMMARY", "hour": row['hour'], "count": row['count']})
        await js.publish("orders.summary", payload.encode())
        print(f"Published: {payload}")
        
    await nc.close()

if __name__ == "__main__":
    asyncio.run(main())
