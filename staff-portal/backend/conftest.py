import sys
from pathlib import Path

# Ensure backend/ is importable so `from app.allocate import allocate` resolves.
sys.path.insert(0, str(Path(__file__).resolve().parent))
