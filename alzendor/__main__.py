"""Runs a game server: python -m alzendor"""

import asyncio
import logging

from .config import Config
from .server import main

config = Config.from_env()
logging.basicConfig(level=config.log_level, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logging.getLogger("websockets").setLevel(logging.WARNING)  # it logs every health check
asyncio.run(main(config))
