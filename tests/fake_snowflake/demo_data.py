"""The demo account: a larger, more varied fake account on top of the base one, for looking at the app.

`add(world)` runs last in World.build when the world is built with demo=True. Each area lives in its
own demo_<area>.py with an `add(b)` that takes a demo_data.B. Names and ids come from
demo_entities.catalog(). The tests never build this; tools/build_demo_db.py does.

demo_billing.add(world) runs after the areas: attribution, daily and org rollups, anomalies.

DEMO_ONLY=compute,security limits the run to those areas while one is being worked on.
"""
from __future__ import annotations

import datetime as dt
import importlib
import os
import random

from tests.fake_snowflake import demo_entities

AREAS = ["compute", "tags", "security", "storage", "pipelines", "queries", "platform"]


class B:
    """Helpers over the World for the demo modules; `rng` is the demo's own generator."""

    def __init__(self, w, area: str):
        self.w = w
        self.as_of = w.as_of
        self.cat = demo_entities.catalog()
        self.rng = random.Random(f"{demo_entities.DEMO_SEED}:{area}")

    def back(self, k: int) -> dt.date:
        return self.as_of - dt.timedelta(days=k)

    def ts(self, k: int, hour: int = 0, minute: int = 0, second: int = 0) -> dt.datetime:
        d = self.back(k)
        return dt.datetime(d.year, d.month, d.day, hour, minute, second)

    def au(self, view: str, **row) -> None:
        self.w.au(view, row)

    def ou(self, view: str, **row) -> None:
        self.w.ou(view, row)

    def show(self, view: str, **row) -> None:
        self.w.show(view, row)


def areas() -> list[str]:
    only = [a.strip() for a in os.environ.get("DEMO_ONLY", "").split(",") if a.strip()]
    return [a for a in AREAS if not only or a in only]


def add(w) -> None:
    for area in areas():
        try:
            mod = importlib.import_module(f"tests.fake_snowflake.demo_{area}")
        except ModuleNotFoundError as exc:
            if exc.name == f"tests.fake_snowflake.demo_{area}":
                continue                     # an area not written yet
            raise
        mod.add(B(w, area))
    from tests.fake_snowflake import demo_billing
    demo_billing.add(w)                      # last: rollups over everything the areas added
