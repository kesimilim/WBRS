"""Offline regression: complete OAuth reply closes socket before the next read."""
import http.client
import json
import socket
import threading
import time
import unittest
from unittest.mock import patch
from native_fcm import _post

class NativeFCMEOFTest(unittest.TestCase):
    def test_complete_connection_close_reply_survives_socket_eof(self):
        expected={'access_token':'synthetic-only','token_type':'Bearer','expires_in':3600}
        raw=json.dumps(expected).encode();connections=[]
        class Connection(http.client.HTTPConnection):
            def __init__(self,host,port,timeout,context):
                self.peer=None;super().__init__(host,port,timeout=timeout);connections.append(self)
            def connect(self):
                self.peer,self.sock=socket.socketpair()
                self.peer.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(raw)).encode()+b'\r\nConnection: close\r\n\r\n'+raw)
            def close(self):
                super().close()
                if self.peer is not None:self.peer.close();self.peer=None
        with patch('native_fcm.http.client.HTTPSConnection',Connection):
            value=_post('oauth2.googleapis.com','/token',b'fixture',{},time.monotonic()+2,threading.Event(),time.monotonic)
        self.assertEqual(value,expected)
        self.assertEqual(len(connections),1)
        self.assertIsNone(connections[0].sock)

if __name__=='__main__':unittest.main()
