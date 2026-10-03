"""Current owner switches, with imported raw and UUID receipts retained."""
from native_credentials import unique_json
from runtime_chat import _integer, _stamp
from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable, MAX_INTEGER
OPERATION='profile.preferences.v1'
KEYS=frozenset({'messages','meetings','sound'})

def _read(c,ex,uid,*,write=False):
    ex("SELECT messages,meetings,sound,revision,DATE_FORMAT(updated_at,'%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') FROM clrs_staging.account_preferences WHERE uid=%s LIMIT 1"+(' FOR UPDATE' if write else ' FOR SHARE'),(uid,))
    row=c.fetchone()
    if row is not None:
        if len(row)!=5 or any(type(v) is not int or v not in (0,1) for v in row[:3]) or _integer(row[3])<1:raise RuntimeUnavailable()
        return {'kind':'native-preferences',**dict(zip(('messages','meetings','sound'),map(bool,row[:3]))),'revision':row[3],'updatedAt':row[4]}
    # profile_page.dart switches are preferences[key] != false. No aliases.
    ex('SELECT legacy_raw FROM clrs_staging.profiles WHERE uid=%s LIMIT 1 FOR SHARE',(uid,))
    source=c.fetchone();values={}
    if source is not None:
        if len(source)!=1:raise RuntimeUnavailable()
        raw=source[0]
        if type(raw) in (str,bytes):
            if len(raw)>131072:raise RuntimeUnavailable()
            raw=unique_json(raw.decode() if type(raw) is bytes else raw)
        if type(raw) is not dict or type(raw.get('fields',{})) is not dict:raise RuntimeUnavailable()
        value=raw.get('fields',{}).get('notificationPreferences',{})
        if type(value) is dict and type(value.get('mapValue',{})) is dict:values=value.get('mapValue',{}).get('fields',{})
        if type(values) is not dict:values={}
    return {'kind':'native-preferences',**{k:values.get(k)!={'booleanValue':False} for k in KEYS},'revision':0,'updatedAt':None}

class RuntimePreferencesService:
    def __init__(self,store):
        self.store=store;store.register_replay_guard(OPERATION,self._replay,response_guard=True)
    def _replay(self,c,ex,uid,request,response):
        if type(request) is not dict or set(request)!=KEYS|{'expectedRevision'} or any(type(request[k]) is not bool for k in KEYS):raise RuntimeUnavailable()
        expected=request['expectedRevision']
        if type(expected) is not int or not 0<=expected<MAX_INTEGER or type(response) is not dict:raise RuntimeUnavailable()
        if response=={'error':'preferences_changed'}:return
        if (set(response)!=KEYS|{'kind','revision','updatedAt'} or response['kind']!='native-preferences'
            or any(response[k]!=request[k] or type(response[k]) is not bool for k in KEYS)
            or response['revision']!=expected+1 or type(response['updatedAt']) is not str):raise RuntimeUnavailable()
        if _read(c,ex,uid)['revision']<response['revision']:raise RuntimeUnavailable()
    def read(self,identity,*,access_token):
        return self.store.read_authenticated(identity,lambda c,ex,uid:_read(c,ex,uid),access_token=access_token)
    def save(self,identity,operation_id,request,*,access_token):
        if (type(request) is not dict or set(request)!=KEYS|{'expectedRevision'}
            or any(type(request[k]) is not bool for k in KEYS) or type(request['expectedRevision']) is not int
            or not 0<=request['expectedRevision']<MAX_INTEGER):raise RuntimeInvalidRequest()
        def action(c,ex,uid):
            before=_read(c,ex,uid,write=True);revision=before['revision']
            if revision!=request['expectedRevision']:return 409,{'error':'preferences_changed'},revision
            created=_stamp(c,ex);values=tuple(int(request[k]) for k in ('messages','meetings','sound')); sql_stamp=created[:-1].replace('T',' ')
            if revision==0:ex('INSERT INTO clrs_staging.account_preferences(uid,messages,meetings,sound,revision,updated_at) VALUES(%s,%s,%s,%s,1,%s)',(uid,*values,sql_stamp))
            else:ex('UPDATE clrs_staging.account_preferences SET messages=%s,meetings=%s,sound=%s,revision=%s,updated_at=%s WHERE uid=%s AND revision=%s',(*values,revision+1,sql_stamp,uid,revision))
            if c.rowcount!=1:raise RuntimeUnavailable()
            return 200,{'kind':'native-preferences',**{k:request[k] for k in KEYS},'revision':revision+1,'updatedAt':created},revision+1
        return self.store.mutate(identity,OPERATION,operation_id,request,action,access_token=access_token)
