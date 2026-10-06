import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_chat_flow.dart';
import 'package:wbrs/service/timeweb_meeting_chat_flow.dart';
import 'support/timeweb_people_fixtures.dart';

const meeting = 'native-reviewed-meeting', op = '12345678-1234-4234-8234-123456789abc', text = '  Точный текст\r\n🙂\t ';
String messageId(String uuid, [String sender = 'A']) => 'tw-meet-msg-${sha256.convert(utf8.encode('clrs-native-meeting-message-v1\u0000${jsonEncode([meeting,sender,uuid])}'))}';
Map<String,dynamic> row(int sequence,{String? uuid,String sender='A',String value='Source text'}) => {
  'meetingId':meeting,'messageId':messageId(uuid??'00000000-0000-4000-8000-${sequence.toRadixString(16).padLeft(12,'0')}',sender),
  'sequence':sequence,'senderUid':sender,'text':value,'createdAt':peopleStamp,
};
Map<String,dynamic> page(List<Object?> items,{int revision=10,String? cursor}) => {
  'kind':'canonical-current','meetingId':meeting,'chatRevision':revision,'ordering':'sequence_desc','items':items,'nextCursor':cursor,'mediaReady':false,
};
TimewebMutationRequest request([String uuid=op]) => TimewebMutationRequest.sendMeetingText(operationId:uuid,meetingId:meeting,text:text);
Map<String,dynamic> envelope(TimewebMutationRequest original,Object? result,{bool absent=false,bool replayed=false,int? revision=1}) => {
  'operation':original.operation,'operationId':original.operationId,'requestHash':original.requestHash,
  'state':absent?'not_found':'committed','replayed':replayed,'result':result,'entityRevision':absent?null:revision,
};
Map<String,dynamic> sent(TimewebMutationRequest original) => {...row(1,uuid:original.operationId,value:text),'chatRevision':1};
TimewebAuthClient client(PeopleWire wire,{DateTime Function()? clock}) => TimewebAuthClient(
  configuration:TimewebAuthConfiguration(endpoint:Uri.parse('https://api.example.invalid'),enabled:true,currentReadsEnabled:true,runtimeWritesEnabled:true),
  secureStore:PeopleStore(),transport:wire,clock:clock??()=>peopleNow,
);
TimewebAppRuntime runtime(PeopleWire wire,Directory root,{bool enabled=true}) => TimewebAppRuntime(
  configuration:TimewebAuthConfiguration(endpoint:Uri.parse('https://api.example.invalid'),enabled:true,currentReadsEnabled:enabled,runtimeWritesEnabled:enabled),
  secureStore:PeopleStore(),transport:wire,clock:()=>peopleNow,deviceId:'synthetic-device',expectedSourceSnapshot:'a'*64,
  clearLocal:()async{},currentOwnProfileEnabled:true,meetingChatJournal:TimewebMeetingChatJournal(directory:()async=>root),
);
List<File> journals(Directory root) => root.listSync(recursive:true).whereType<File>().where((f)=>f.path.endsWith('.json')).toList();
Matcher authError(TimewebAuthError value) => isA<TimewebAuthException>().having((e)=>e.error,'error',value);
Future<void> tick(bool Function() ready) async {for(var i=0;i<100&&!ready();i++){await Future<void>.delayed(const Duration(milliseconds:2));}expect(ready(),isTrue);}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('messages exact descending window binds tail/revision/target/limit/original expiry and nested runtime guards',()async{
    var now=peopleNow;
    final wire=PeopleWire((call)async{
      expect(call.url.path,'/v1/runtime/meetings/$meeting/messages');expect(call.followRedirects,isFalse);
      return peopleReply(call.url.queryParameters.containsKey('cursor')?page([row(8)],revision:11,cursor:'second'):page([row(10),row(9)],cursor:'first'));
    });final owner=client(wire,clock:()=>now);
    try{
      await owner.restore();final first=await owner.readMeetingMessages(meeting,limit:2);
      expect(first.items.map((v)=>v.sequence),[10,9]);expect(first.meetingId,meeting);expect(first.mediaReady,isFalse);
      final original=first.nextCursor!;now=now.add(const Duration(seconds:100));final second=await owner.readMeetingMessages(meeting,limit:2,cursor:original);
      expect(second.items.single.sequence,8);expect(second.chatRevision,11);
      await expectLater(owner.readMeetingMessages('other',limit:2,cursor:original),throwsA(authError(TimewebAuthError.invalidRequest)));
      await expectLater(owner.readMeetingMessages(meeting,limit:1,cursor:original),throwsA(authError(TimewebAuthError.invalidRequest)));
      await expectLater(owner.readMeetingParticipants(meeting,limit:2,cursor:original),throwsA(authError(TimewebAuthError.invalidRequest)));
      var live=true;void guard(){if(!live)throw const TimewebAuthException(TimewebAuthOperation.currentRead,TimewebAuthError.staleSession);}
      final bound=first.bindSessionGuard(guard),item=bound.items.first,cursor=bound.nextCursor!;live=false;
      expect(()=>item.text,throwsA(authError(TimewebAuthError.staleSession)));expect(()=>cursor.requireCurrent(),throwsA(authError(TimewebAuthError.staleSession)));
      now=now.add(const Duration(seconds:200));await expectLater(owner.readMeetingMessages(meeting,limit:2,cursor:second.nextCursor),throwsA(authError(TimewebAuthError.invalidRequest)));
    }finally{await owner.stop();}
    for(final invalid in [page([],cursor:'empty'),page([row(1),row(2)]),page([row(1),row(1)]),
        page([{...row(1),'url':'https://invalid.example'}]),page([{...row(1),'createdAt':null}]),page([{...row(1),'text':' '}]),
        page([{...row(1),'sequence':1.0}]),page([{...row(1),'meetingId':'foreign'}]),page([{...row(1),'quote':null}])]){
      final check=client(PeopleWire((_)async=>peopleReply(invalid)));try{await check.restore();await expectLater(check.readMeetingMessages(meeting),throwsA(authError(TimewebAuthError.invalidResponse)));}finally{await check.stop();}
    }
    for(final invalid in [page([row(10)],cursor:'third'),page([row(8)],revision:9),page([row(8)],cursor:'first')]){
      var calls=0;final check=client(PeopleWire((_)async=>peopleReply(++calls==1?page([row(10),row(9)],cursor:'first'):invalid)));
      try{await check.restore();final first=await check.readMeetingMessages(meeting);await expectLater(check.readMeetingMessages(meeting,cursor:first.nextCursor),throwsA(authError(TimewebAuthError.invalidResponse)));}finally{await check.stop();}
    }
  });

  test('original text UUID/hash flushed before one POST; lost ACK restart lookup only; disk ACK precedes current GET rendering',()async{
    final root=await Directory.systemTemp.createTemp('native-meeting-text-');TimewebMutationRequest? original;var stage='absent',visible=false;
    final wire=PeopleWire((call)async{
      if(call.url.path.endsWith('/messages')&&call.method=='GET')return peopleReply(page(visible?[row(1,uuid:original!.operationId,value:text)]:[],revision:visible?1:0));
      if(call.method=='POST'){
        final body=jsonDecode((call as http.Request).body);original=request(body['operationId']);
        expect(body,{'operationId':original!.operationId,'text':text});expect(call.url.path,'/v1/runtime/meetings/$meeting/messages');
        final saved=jsonDecode(await journals(root).single.readAsString());expect(saved['fields'],{'meetingId':meeting,'text':text});expect(saved['uid'],'A');
        expect(saved['operationId'],original!.operationId);expect(saved['requestHash'],original!.requestHash);
        expect(original!.requestHash,sha256.convert(utf8.encode(jsonEncode({'meetingId':meeting,'text':text}))).toString());
        throw StateError('Synthetic ACK lost after commit');
      }
      expect(call.url.path,'/v1/runtime/operations/meeting.send-text.v1/${original!.operationId}');expect(call.url.queryParameters,{'requestHash':original!.requestHash});
      return peopleReply(envelope(original!,stage=='absent'?null:sent(original!),absent:stage=='absent',replayed:stage!='absent'),status:stage=='absent'?200:201);
    });final first=runtime(wire,root);TimewebAppRuntime? restart;
    try{
      await first.start(remember:true);final flow=await first.openMeetingConversation(meeting);expect(flow.messages,isEmpty);
      final a=flow.send(text),b=flow.send(text);expect(identical(a,b),isTrue);expect(await a,TimewebChatWriteOutcome.unknown);expect(flow.pendingText,text);
      flow.close();await first.stop();restart=runtime(wire,root);await restart.start(remember:true);final restored=await restart.openMeetingConversation(meeting);
      expect(restored.sendNeedsCheck,isTrue);expect(restored.pendingText,text);expect(()=>restored.send('Another'),throwsStateError);
      expect(await restored.checkSend(),TimewebChatWriteOutcome.unknown);expect(journals(root),hasLength(1));
      stage='confirmed';expect(await restored.checkSend(),TimewebChatWriteOutcome.confirmed);expect(journals(root),isEmpty);expect(restored.messages,isEmpty);
      visible=true;await restored.loadUpdates();expect(restored.messages.single.text,text);restored.acceptDisplayedSendResult();expect(restored.sendNeedsCheck,isFalse);
      expect(wire.calls.where((c)=>c.method=='POST'),hasLength(1));restored.close();
    }finally{await restart?.stop();await first.stop();await root.delete(recursive:true);}
  });

  test('target denial clears held message capability without healthy logout; pending disk survives denial and reopen',()async{
    final root=await Directory.systemTemp.createTemp('native-meeting-deny-');var deny=false;
    final wire=PeopleWire((call)async{
      if(call.method=='POST')return peopleReply({},status:503);
      if(call.url.path.contains('/operations/')||deny)return peopleReply({'error':'meeting_unavailable'},status:404);
      return peopleReply(page([row(1)],revision:1));
    });final owner=runtime(wire,root);
    try{
      await owner.start(remember:true);final flow=await owner.openMeetingConversation(meeting),held=flow.messages.single;
      expect(await flow.send(text),TimewebChatWriteOutcome.unknown);expect(journals(root),hasLength(1));
      expect(await flow.checkSend(),TimewebChatWriteOutcome.unknown);expect(flow.targetAvailable,isFalse);
      expect(()=>held.text,throwsA(isA<TimewebMeetingNotFound>()));expect(()=>flow.messages,throwsA(isA<TimewebMeetingNotFound>()));
      expect(owner.client.currentUid,'A');expect(journals(root),hasLength(1));flow.close();deny=true;
      await expectLater(owner.openMeetingConversation(meeting),throwsA(isA<TimewebMeetingNotFound>()));
      expect(journals(root),hasLength(1));expect(wire.calls.where((c)=>c.url.path.contains('/auth/')),isEmpty);
    }finally{await owner.stop();await root.delete(recursive:true);}
  });

  test('receipt exact message derivation/sender/text/stamp/revision; four committed errors only, all short errors UNKNOWN/no ACK',()async{
    final original=request();
    for(final value in ['', ' ', 'x'*4097, 'x\u0000', 'x\u007f', '\ud800']){expect(()=>TimewebMutationRequest.sendMeetingText(operationId:op,meetingId:meeting,text:value),throwsArgumentError);}
    for(final invalid in [{'messageId':messageId(op,'B')},{'senderUid':'B'},{'text':'rewrite'},{'sequence':0},{'createdAt':peopleStamp.replaceAll('Z','+00:00')},{'chatRevision':0},{'raw':{}}]){
      final owner=client(PeopleWire((_)async=>peopleReply(envelope(original,{...sent(original),...invalid}),status:201)));
      try{await owner.restore();final result=await owner.mutate(owner.bindMutation(original,expectedOwnerUid:'A'));expect(result.state,TimewebMutationState.unknown);expect(result.canAcknowledge,isFalse);}finally{await owner.stop();}
    }
    for(final row in [(404,'meeting_not_found',TimewebMutationFailure.meetingNotFound),(404,'profile_not_found',TimewebMutationFailure.notFound),
        (409,'meeting_unavailable',TimewebMutationFailure.meetingUnavailable),(409,'profile_not_ready',TimewebMutationFailure.profileNotReady),(409,'quote_unavailable',null)]){
      final owner=client(PeopleWire((_)async=>peopleReply(envelope(original,{'error':row.$2},revision:null),status:row.$1)));
      try{await owner.restore();final result=await owner.mutate(owner.bindMutation(original,expectedOwnerUid:'A'));expect(result.canAcknowledge,row.$3!=null);expect(result.failure,row.$3);}finally{await owner.stop();}
    }
    for(final status in [400,401,404,409,429,503]){
      final owner=client(PeopleWire((_)async=>peopleReply({'error':status==400?'invalid_request':status==409?'operation_conflict':status==429?'rate_limited':'not_found'},status:status)));
      try{await owner.restore();final result=await owner.mutate(owner.bindMutation(original,expectedOwnerUid:'A'));expect(result.state,TimewebMutationState.unknown);expect(result.canAcknowledge,isFalse);}finally{await owner.stop();}
    }
    var calls=0;final owner=client(PeopleWire((_)async=>++calls==1?peopleReply(envelope(original,sent(original)),status:201):peopleReply({'error':'meeting_unavailable'},status:404)));
    try{await owner.restore();final ref=owner.bindMutation(original,expectedOwnerUid:'A');final receipt=(await owner.mutate(ref)).sentMeetingMessage!;
      expect(receipt.messageId,messageId(op));expect(receipt.chatRevision,1);expect((await owner.reconcileMutation(ref)).canAcknowledge,isFalse);expect(owner.currentUid,'A');
      await owner.stop();expect(()=>receipt.text,throwsA(isA<TimewebAuthException>()));
    }finally{await owner.stop();}
  });

  test('late A ACK cannot clear original for B; stop drains actual transport; exact journal corruption refuses before POST',()async{
    final root=await Directory.systemTemp.createTemp('native-meeting-aba-');final late=Completer<http.StreamedResponse>();TimewebMutationRequest? original;http.AbortableRequest? post;
    final wire=PeopleWire((call)async{
      if(call.url.path=='/v1/auth/login')return peopleReply(peopleTokens('B'));
      if(call.method=='GET')return peopleReply(page([],revision:0));
      post=call as http.AbortableRequest;original=request(jsonDecode(post!.body)['operationId']);return late.future;
    });final owner=runtime(wire,root);TimewebAppRuntime? recovered;
    try{
      await owner.start(remember:true);final a=await owner.openMeetingConversation(meeting);final pending=a.send(text),stale=expectLater(pending,throwsA(authError(TimewebAuthError.staleSession)));
      await tick(()=>original!=null);var aborted=false;post!.abortTrigger!.then((_)=>aborted=true);
      await owner.login(email:'synthetic-b@example.invalid',password:'synthetic');await tick(()=>aborted);
      expect(()=>a.pendingText,throwsA(isA<AppSessionException>()));final b=await owner.openMeetingConversation(meeting);expect(b.sendNeedsCheck,isFalse);b.close();
      var drained=false;final stop=owner.stop().then((result){drained=true;return result;});await Future<void>.delayed(Duration.zero);expect(drained,isFalse);
      late.complete(peopleReply(envelope(original!,sent(original!)),status:201));await stale;expect(await stop,isTrue);expect(journals(root),hasLength(1));
      final file=journals(root).single,data=jsonDecode(await file.readAsString());await file.writeAsString(jsonEncode({...data,'requestHash':'a'*64}),flush:true);
      recovered=runtime(wire,root);await recovered.start(remember:true);await expectLater(recovered.openMeetingConversation(meeting),throwsA(isA<FormatException>()));
      expect(wire.calls.where((c)=>c.method=='POST'&&c.url.path.endsWith('/messages')),hasLength(1));expect(journals(root),hasLength(1));
    }finally{if(!late.isCompleted)late.complete(peopleReply({},status:503));await recovered?.stop();await owner.stop();await root.delete(recursive:true);}
  });

  test('messages use common four actual read slots, no new flag or default activation',()async{
    final held=<Completer<http.StreamedResponse>>[];final wire=PeopleWire((_) {final response=Completer<http.StreamedResponse>();held.add(response);return response.future;});final owner=client(wire);
    try{
      await owner.restore();final reads=[owner.readMeetingMessages(meeting),owner.readMeeting('two'),owner.readMeetingParticipants('three'),owner.readPeople(await TimewebPeopleFilters.fromCatalog())];
      final stale=[for(final read in reads)expectLater(read,throwsA(authError(TimewebAuthError.staleSession)))];await tick(()=>held.length==4);
      await expectLater(owner.readMeetingMessages('fifth'),throwsA(authError(TimewebAuthError.unavailable)));expect(wire.calls,hasLength(4));
      final stop=owner.stop();for(final response in held){response.complete(peopleReply({},status:503));}await Future.wait(stale);await stop;
    }finally{for(final response in held){if(!response.isCompleted)response.complete(peopleReply({},status:503));}await owner.stop();}
    final root=await Directory.systemTemp.createTemp('native-meeting-off-');final noWire=PeopleWire((_)async=>throw StateError('No HTTP'));final off=runtime(noWire,root,enabled:false);
    try{await off.start(remember:true);await expectLater(off.openMeetingConversation(meeting),throwsStateError);expect(noWire.calls,isEmpty);expect(journals(root),isEmpty);}finally{await off.stop();await root.delete(recursive:true);}
  });
}
