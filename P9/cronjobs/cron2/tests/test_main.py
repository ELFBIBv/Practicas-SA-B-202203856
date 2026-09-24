import os
from unittest.mock import AsyncMock, MagicMock

os.environ.setdefault("DB_HOST", "127.0.0.1")
os.environ.setdefault("DB_USER", "root")
os.environ.setdefault("DB_PASSWORD", "root")
os.environ.setdefault("DB_NAME", "cron_test")

import mysql.connector  # noqa: E402
import pytest  # noqa: E402

import main  # noqa: E402


def _seed_cron_log():
    conn = mysql.connector.connect(
        host=main.db_host, user=main.db_user, password=main.db_pass, database=main.db_name
    )
    cursor = conn.cursor()
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS cron_logs (
            id INT AUTO_INCREMENT PRIMARY KEY,
            execution_time DATETIME,
            student_id VARCHAR(20)
        )
        """
    )
    cursor.execute(
        "INSERT INTO cron_logs (execution_time, student_id) VALUES (NOW(), %s)",
        ("202203856",),
    )
    conn.commit()
    conn.close()


@pytest.mark.asyncio
async def test_main_publishes_a_summary_when_there_is_data(monkeypatch):
    """La lectura/agrupación corre contra el MySQL real de la CI; NATS se
    simula porque levantar JetStream con un stream configurado no aporta a
    esta prueba unitaria."""
    _seed_cron_log()

    fake_js = MagicMock()
    fake_js.publish = AsyncMock()
    fake_nc = AsyncMock()
    fake_nc.jetstream = MagicMock(return_value=fake_js)
    monkeypatch.setattr(main.nats, "connect", AsyncMock(return_value=fake_nc))

    await main.main()

    assert fake_js.publish.await_count >= 1
    published_subject = fake_js.publish.await_args.args[0]
    assert published_subject == "orders.summary"
