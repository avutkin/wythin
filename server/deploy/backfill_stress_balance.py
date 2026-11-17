"""Run after migrate.py, with the same environment; safe to resume/repeat."""
import asyncio
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from server.db import init_pool, close_pool, get_pool
from server.stress_balance import backfill_stress_balance


async def main():
    await init_pool()
    try:
        print(f'Filled {await backfill_stress_balance(get_pool())} missing Stress Balance values')
    finally:
        await close_pool()


if __name__ == '__main__':
    asyncio.run(main())
