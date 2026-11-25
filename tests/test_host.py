"""Run: python -m unittest discover -s tests -v"""
import asyncio
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'windows-host'))
import host

class FakeSocket:
    def __init__(self, events):
        self.events = events
        self.sent = []
    def __aiter__(self):
        async def iterator():
            for item in self.events:
                yield json.dumps(item)
        return iterator()
    async def send(self, payload):
        self.sent.append(json.loads(payload))

class ServerTests(unittest.IsolatedAsyncioTestCase):
    async def test_duplicate_on_same_or_other_phone_rejected(self):
        server = host.ControllerServer('123456')
        first = FakeSocket([
            {'type':'hello', 'pin':'123456', 'name':'One'},
            {'type':'assign','control':'a','key':'W'},
            {'type':'assign','control':'b','key':'W'},
        ])
        second = FakeSocket([
            {'type':'hello', 'pin':'123456', 'name':'Two'},
            {'type':'assign','control':'c','key':'W'},
        ])
        # Keep connections alive during checks; handler normally releases on disconnect.
        async def connected(sock):
            await server.handler(sock)
        # Use direct host-level reservation check through an active client.
        class HoldingSocket(FakeSocket):
            def __aiter__(self):
                async def iterator():
                    for event in self.events:
                        yield json.dumps(event)
                    await asyncio.sleep(0.05)
                return iterator()
        one = HoldingSocket(first.events)
        two = HoldingSocket(second.events)
        a = asyncio.create_task(connected(one))
        await asyncio.sleep(0.005)
        b = asyncio.create_task(connected(two))
        await asyncio.gather(a,b)
        self.assertTrue(any('already assigned' in x.get('message','') for x in one.sent))
        self.assertTrue(any('already assigned' in x.get('message','') for x in two.sent))

if __name__ == '__main__':
    unittest.main()
