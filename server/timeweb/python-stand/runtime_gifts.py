"""Native gift inventory and atomic silver debit/transfer, not payment callbacks."""
from __future__ import annotations
import hashlib
import re
from datetime import datetime, timezone
import time

from runtime_social import ident
from runtime_chat import _pair, _ChatFailure, _events, _stamp, _integer
from runtime_personal_chat import _visible_pair, _PersonalFailure
from runtime_mutations import RuntimeInvalidRequest, RuntimeRejected, RuntimeUnavailable, canonical_json, MAX_INTEGER

OPS=frozenset({'gift.buy.v1','gift.send.v1'})


def gift_id(value):
    # Preserve the original local-asset inventory keys, including their '/'.
    if type(value) is not str or re.fullmatch(r'assets/gifts/(?:[1-9]|[1-5][0-9]|6[0-4])\.png',value) is None:
        raise RuntimeInvalidRequest()
    return value


class GiftAccessDenied(RuntimeRejected):
    pass


def _gift(c,ex,gift_id):
    ex('SELECT gift_id,asset_path,name_key,price_ag,active FROM clrs_staging.gift_catalog WHERE gift_id=%s LIMIT 1 FOR SHARE',(gift_id,))
    r=c.fetchone()
    if r is None: raise GiftAccessDenied()
    if len(r)!=5: raise RuntimeUnavailable()
    if (r[0]!=gift_id or type(r[1]) is not str or type(r[2]) is not str or len(r[2])>191
            or r[1]!=gift_id or not r[2] or type(r[4]) is not int or r[4] not in (0,1)
            or r[3] is not None and (type(r[3]) is not int or not 0<=r[3]<=MAX_INTEGER)):
        raise RuntimeUnavailable()
    if r[4]!=1: raise GiftAccessDenied()
    return {'id':gift_id,'assetPath':r[1],'name':r[2],'priceAg':r[3]}


def _derived(uid,operation_id):
    return 'tw-gift-'+hashlib.sha256(canonical_json([uid,operation_id])).hexdigest()


class RuntimeGiftService:
    def __init__(self,store,*,clock=time.time):
        if store is None: raise RuntimeUnavailable()
        self.store=store;self.clock=clock
        for op in OPS:store.register_replay_guard(op,self._replay,response_guard=True,operation_id_guard=True)

    def _replay(self,c,ex,uid,operation_id,request,response):
        kind=request.get('kind')
        if kind not in {'buy','send'} or type(response) is not dict: raise RuntimeUnavailable()
        selected=gift_id(request.get('giftId')); gift=_gift(c,ex,selected)
        shapes={'buy':{'kind','giftId','expectedWalletRevision'},'send':{'kind','giftId','chatId','expectedOwnedQuantity'}}
        if set(request)!=shapes[kind]:raise RuntimeUnavailable()
        expected=request['expectedWalletRevision' if kind=='buy' else 'expectedOwnedQuantity']
        if type(expected) is not int or not 0<=expected<=MAX_INTEGER:raise RuntimeUnavailable()
        if 'error' in response:
            errors={'buy':{'balance_changed','insufficient_silver'},'send':{'inventory_changed','gift_not_owned'}}
            if set(response)!={'error'} or response['error'] not in errors[kind]: raise RuntimeUnavailable()
            return
        identifier=_derived(uid,operation_id)
        if kind=='buy':
            if (set(response)!={'giftId','entryId','balanceAg','walletRevision'} or response['giftId']!=selected or response['entryId']!=identifier
                or type(response['walletRevision']) is not int or response['walletRevision']!=expected+1): raise RuntimeUnavailable()
            ex('SELECT uid,reason,source_kind,source_id,balance_after_ag FROM clrs_staging.wallet_ledger WHERE entry_id=%s LIMIT 1 FOR SHARE',(identifier,))
            row=c.fetchone()
            if row is None or tuple(row)!=(uid,'gift_purchase','gift',identifier,response['balanceAg']): raise RuntimeUnavailable()
        else:
            message_id='tw-'+hashlib.sha256(canonical_json([uid,operation_id,'gift-notice'])).hexdigest()
            if (set(response)!={'giftId','transferId','recipientUid','chatId','messageId','sequence'} or response['transferId']!=identifier
                or response['giftId']!=selected or response['chatId']!=ident(request['chatId']) or response['messageId']!=message_id): raise RuntimeUnavailable()
            try:pair=_pair(c,ex,uid,request['chatId'],readonly=True)
            except _ChatFailure: raise GiftAccessDenied() from None
            try:
                low,high=sorted((uid,pair['peer']),key=lambda item:item.encode())
                _visible_pair(c,ex,low,high,datetime.fromtimestamp(self.clock(),timezone.utc))
            except _PersonalFailure:raise GiftAccessDenied() from None
            if pair['peer']!=response['recipientUid']: raise RuntimeUnavailable()
            ex('SELECT gift_id,sender_uid,recipient_uid,chat_id,message_id FROM clrs_staging.gift_transfers WHERE transfer_id=%s LIMIT 1 FOR SHARE',(identifier,))
            row=c.fetchone()
            if row is None or tuple(row)!=(selected,uid,pair['peer'],request['chatId'],message_id): raise RuntimeUnavailable()
            ex('SELECT sequence,sender_uid,body,gift_notice_id FROM clrs_staging.chat_messages WHERE chat_id=%s AND message_id=%s LIMIT 1 FOR SHARE',(request['chatId'],message_id))
            row=c.fetchone()
            if row is None or tuple(row)!=(response['sequence'],uid,'Подарок «'+gift['name']+'» ❤️',identifier):raise RuntimeUnavailable()

    def mine(self,identity,*,access_token):
        def read(c,ex,uid):
            ex('SELECT balance_ag,revision FROM clrs_staging.wallets WHERE uid=%s LIMIT 1 FOR SHARE',(uid,));wallet=c.fetchone()
            if wallet is None or len(wallet)!=2: raise RuntimeUnavailable()
            balance,revision=map(_integer,wallet)
            ex('SELECT gift_id,owned_quantity,received_quantity FROM clrs_staging.gift_inventory WHERE uid=%s ORDER BY gift_id LIMIT 101 FOR SHARE',(uid,));rows=c.fetchall()
            if len(rows)>100:raise RuntimeUnavailable()
            if any(len(r)!=3 for r in rows):raise RuntimeUnavailable()
            items=[{'giftId':gift_id(r[0]),'ownedQuantity':_integer(r[1]),'receivedQuantity':_integer(r[2])} for r in rows]
            ex('SELECT gift_id,asset_path,name_key,price_ag,active FROM clrs_staging.gift_catalog ORDER BY gift_id LIMIT 101 FOR SHARE'); rows=c.fetchall()
            if len(rows)>100: raise RuntimeUnavailable()
            catalog=[]
            for r in rows:
                if len(r)!=5 or type(r[4]) is not int or r[4] not in (0,1):raise RuntimeUnavailable()
                if r[4]:
                    selected=gift_id(r[0])
                    if r[1]!=selected or type(r[2]) is not str or not 1<=len(r[2])<=191:raise RuntimeUnavailable()
                    catalog.append({'id':selected,'assetPath':r[1],'name':r[2],'priceAg':None if r[3] is None else _integer(r[3])})
            return {'kind':'native-gifts','balanceAg':balance,'walletRevision':revision,'inventory':items,'catalog':catalog}
        return self.store.read_authenticated(identity,read,access_token=access_token)

    def perform(self,identity,operation_id,request,*,access_token):
        if type(request) is not dict:raise RuntimeInvalidRequest()
        kind=request.get('kind')
        shapes={'buy':{'kind','giftId','expectedWalletRevision'},'send':{'kind','giftId','chatId','expectedOwnedQuantity'}}
        if kind not in shapes or set(request)!=shapes[kind]:raise RuntimeInvalidRequest()
        selected=gift_id(request['giftId'])
        expected=request['expectedWalletRevision' if kind=='buy' else 'expectedOwnedQuantity']
        if type(expected) is not int or not 0<=expected<=MAX_INTEGER:raise RuntimeInvalidRequest()
        if kind=='send':chat_id=ident(request['chatId'])
        identifier=_derived(identity.uid,operation_id)
        def action(c,ex,uid):
            gift=_gift(c,ex,selected)
            if kind=='buy':
                price=gift['priceAg']
                # Price unknown/zero is not interpreted as a free gift.
                if price is None or price<=0:raise GiftAccessDenied()
                ex('SELECT balance_ag,revision FROM clrs_staging.wallets WHERE uid=%s LIMIT 1 FOR UPDATE',(uid,));r=c.fetchone()
                if r is None or len(r)!=2:raise RuntimeUnavailable()
                balance,revision=map(_integer,r)
                if revision!=expected:return 409,{'error':'balance_changed'},revision
                if balance<price:return 409,{'error':'insufficient_silver'},revision
                if revision==MAX_INTEGER:raise RuntimeUnavailable()
                ex('SELECT owned_quantity FROM clrs_staging.gift_inventory WHERE uid=%s AND gift_id=%s LIMIT 1 FOR UPDATE',(uid,selected));owned_row=c.fetchone()
                if owned_row is not None and (len(owned_row)!=1 or _integer(owned_row[0])==MAX_INTEGER):raise RuntimeUnavailable()
                ex('UPDATE clrs_staging.wallets SET balance_ag=%s,revision=%s,updated_at=UTC_TIMESTAMP(6) WHERE uid=%s AND balance_ag=%s AND revision=%s',(balance-price,revision+1,uid,balance,revision))
                if c.rowcount!=1:raise RuntimeUnavailable()
                ex("INSERT INTO clrs_staging.wallet_ledger(entry_id,uid,delta_ag,balance_after_ag,reason,source_kind,source_id) VALUES(%s,%s,%s,%s,'gift_purchase','gift',%s)",(identifier,uid,-price,balance-price,identifier))
                ex('INSERT INTO clrs_staging.gift_inventory(uid,gift_id,owned_quantity,received_quantity) VALUES(%s,%s,1,0) ON DUPLICATE KEY UPDATE owned_quantity=owned_quantity+1',(uid,selected))
                return 201,{'giftId':selected,'entryId':identifier,'balanceAg':balance-price,'walletRevision':revision+1},revision+1
            try:
                pair=_pair(c,ex,uid,chat_id)
                low,high=sorted((uid,pair['peer']),key=lambda item:item.encode())
                _visible_pair(c,ex,low,high,datetime.fromtimestamp(self.clock(),timezone.utc))
            except (_ChatFailure,_PersonalFailure):raise GiftAccessDenied() from None
            inventories={}
            for member in (low,high):
                ex('SELECT owned_quantity,received_quantity FROM clrs_staging.gift_inventory WHERE uid=%s AND gift_id=%s LIMIT 1 FOR UPDATE',(member,selected));r=c.fetchone()
                if r is not None and len(r)!=2:raise RuntimeUnavailable()
                inventories[member]=(0,0) if r is None else tuple(map(_integer,r))
            owned=inventories[uid][0]
            if owned!=expected:return 409,{'error':'inventory_changed'},None
            if owned<1:return 409,{'error':'gift_not_owned'},None
            if pair['sequence']==MAX_INTEGER or pair['revision']==MAX_INTEGER or inventories[pair['peer']][1]==MAX_INTEGER:raise RuntimeUnavailable()
            ex('UPDATE clrs_staging.gift_inventory SET owned_quantity=owned_quantity-1 WHERE uid=%s AND gift_id=%s AND owned_quantity=%s',(uid,selected,owned))
            if c.rowcount!=1:raise RuntimeUnavailable()
            ex('INSERT INTO clrs_staging.gift_inventory(uid,gift_id,owned_quantity,received_quantity) VALUES(%s,%s,0,1) ON DUPLICATE KEY UPDATE received_quantity=received_quantity+1',(pair['peer'],selected))
            created=_stamp(c,ex);sql_created=created[:-1].replace('T',' ')
            message_id='tw-'+hashlib.sha256(canonical_json([uid,operation_id,'gift-notice'])).hexdigest()
            sequence,revision=pair['sequence']+1,pair['revision']+1
            text='Подарок «'+gift['name']+'» ❤️'
            ex("INSERT INTO clrs_staging.chat_messages(chat_id,message_id,sequence,sender_uid,body,gift_notice_id,created_at,legacy_raw) VALUES(%s,%s,%s,%s,%s,%s,%s,%s)",(chat_id,message_id,sequence,uid,text,identifier,sql_created,canonical_json({'runtime':{'version':1,'quote':None},'gift':{'id':selected,'assetPath':gift['assetPath']}}).decode()))
            ex('INSERT INTO clrs_staging.gift_transfers(transfer_id,gift_id,sender_uid,recipient_uid,chat_id,message_id,created_at) VALUES(%s,%s,%s,%s,%s,%s,%s)',(identifier,selected,uid,pair['peer'],chat_id,message_id,sql_created))
            ex('UPDATE clrs_staging.chats SET last_sequence=%s,revision=%s,updated_at=%s WHERE chat_id=%s AND last_sequence=%s AND revision=%s',(sequence,revision,sql_created,chat_id,pair['sequence'],pair['revision']))
            if c.rowcount!=1:raise RuntimeUnavailable()
            _events(c,ex,(uid,pair['peer']),'chat.message.created.v1',{'chatId':chat_id,'messageId':message_id,'sequence':sequence,'senderUid':uid,'chatRevision':revision,'createdAt':created})
            return 201,{'giftId':selected,'transferId':identifier,'recipientUid':pair['peer'],'chatId':chat_id,'messageId':message_id,'sequence':sequence},None
        return self.store.mutate(identity,'gift.buy.v1' if kind=='buy' else 'gift.send.v1',operation_id,request,action,access_token=access_token)
