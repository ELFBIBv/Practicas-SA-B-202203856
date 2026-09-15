import os

os.environ.setdefault("DB_HOST", "127.0.0.1")
os.environ.setdefault("DB_USER", "root")
os.environ.setdefault("DB_PASSWORD", "root")
os.environ.setdefault("DB_NAME", "cron_test")

import mysql.connector  # noqa: E402

import main  # noqa: E402


def test_main_inserts_a_log_row_for_the_student():
    main.main()

    conn = mysql.connector.connect(
        host=main.db_host, user=main.db_user, password=main.db_pass, database=main.db_name
    )
    cursor = conn.cursor(dictionary=True)
    cursor.execute("SELECT * FROM cron_logs WHERE student_id = %s", (main.student_id,))
    rows = cursor.fetchall()
    conn.close()

    assert len(rows) >= 1
    assert rows[-1]["student_id"] == main.student_id
