import os
import mysql.connector
from datetime import datetime
import pytz

db_host = os.getenv("DB_HOST", "sa-platform-mysql")
db_user = os.getenv("DB_USER", "user")
db_pass = os.getenv("DB_PASSWORD", "password123")
db_name = os.getenv("DB_NAME", "sa_p5")
student_id = "202203856"

def main():
    conn = mysql.connector.connect(host=db_host, user=db_user, password=db_pass, database=db_name)
    cursor = conn.cursor()
    
    # Create table if not exists
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS cron_logs (
        id INT AUTO_INCREMENT PRIMARY KEY,
        execution_time DATETIME,
        student_id VARCHAR(20)
    )
    """)
    
    tz = pytz.timezone('America/Guatemala') # GMT-6
    now = datetime.now(tz)
    
    cursor.execute("INSERT INTO cron_logs (execution_time, student_id) VALUES (%s, %s)", (now.strftime('%Y-%m-%d %H:%M:%S'), student_id))
    conn.commit()
    print(f"Inserted record for {student_id} at {now}")
    conn.close()

if __name__ == "__main__":
    main()
