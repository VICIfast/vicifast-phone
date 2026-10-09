import 'package:flutter_test/flutter_test.dart';
import 'package:vicifast_phone/core/errors.dart';
import 'package:vicifast_phone/data/agent_api.dart';
import 'package:vicifast_phone/core/format.dart';
import 'package:vicifast_phone/data/models.dart';
import 'package:vicifast_phone/platform/sip_models.dart';
import 'package:vicifast_phone/platform/updater.dart';
import 'package:vicifast_phone/state/line.dart';

void main() {
  group('server shapes', () {
    test('login SIP block, both key spellings', () {
      final a = SipCredentials.fromJson({
        'username': '2001',
        'password': 'x',
        'registerServer': 'pbx.example.com',
        'transport': 'UDP',
        'port': 5060,
      });
      final b = SipCredentials.fromJson({
        'username': '2001',
        'password': 'x',
        'register_server': 'pbx.example.com',
        'port': '5060',
      });
      expect(a?.server, 'pbx.example.com');
      expect(a?.transport, 'udp');
      expect(b?.port, 5060);
      expect(SipCredentials.fromJson({'username': '2001'}), isNull);
    });

    test('current-lead with VICIdial strings for numbers', () {
      final c = CallContext.fromJson({
        'ok': true,
        'callerid': 'V1009103215000086059',
        'uniqueid': '1728480000.123',
        'campaign_id': 'DID_INBOUND',
        'lead': {
          'lead_id': '86059',
          'first_name': 'Robert',
          'last_name': 'Hayes',
          'phone_number': '3055550142',
          'city': 'Miami',
          'state': 'FL',
          'gmt_offset_now': '-4.00',
          'status': 'CALLBK',
          'comments': '',
        },
      });
      expect(c.displayName, 'Robert Hayes');
      expect(c.phone, '3055550142');
      expect(c.lead?.gmtOffset, -4.0);
      expect(c.lead?.place, 'Miami, FL');
      expect(c.queueId, 'DID_INBOUND');
    });

    test('a call context survives being saved and restored', () {
      const c = CallContext(
        callerId: 'V1',
        uniqueid: 'u1',
        queueId: 'P1',
        queueName: 'P1 Inbound',
        phone: '3055550142',
        lead: Lead(id: '9', firstName: 'Ann', gmtOffset: -5),
      );
      final back = CallContext.fromJson(c.toJson());
      expect(back.uniqueid, 'u1');
      expect(back.queueName, 'P1 Inbound');
      expect(back.lead?.id, '9');
      expect(back.lead?.gmtOffset, -5);
    });

    test('call log rows from both lists', () {
      final inbound = CallRecord.fromJson({
        'close_call_id': 77,
        'call_date': '2026-10-09 10:21:07',
        'length_in_sec': '266',
        'status': 'ni',
        'phone_number': '3055550142',
        'campaign_id': 'DID_INBOUND',
        'lead_id': '86059',
      }, inbound: true);
      final outbound = CallRecord.fromJson({
        'uniqueid': '1728.5',
        'call_date': '0000-00-00 00:00:00',
        'length_in_sec': 12,
        'status': 'SALE',
      }, inbound: false);
      expect(inbound.id, '77');
      expect(inbound.seconds, 266);
      expect(inbound.result, 'NI');
      expect(inbound.at, DateTime(2026, 10, 9, 10, 21, 7));
      expect(outbound.at, isNull);
    });

    test('dispositions keep their flags', () {
      final d = Disposition.fromJson({
        'code': 'DNC',
        'label': 'Do not call',
        'dnc': true,
        'sale': false,
        'callback': false,
      });
      expect(d.code, 'DNC');
      expect(d.dnc, isTrue);
      // VICIdial codes may be lowercase or carry underscores; they go back exactly as listed.
      expect(Disposition.fromJson({'code': 'cb_Hld', 'label': 'Hold callback'}).code, 'cb_Hld');
    });

    test('a session survives storage, with its shift', () {
      final s = Session(
        slug: 'acme',
        user: '2001',
        password: 'p',
        expiresAt: DateTime.utc(2026, 10, 10),
        sip: const SipCredentials(username: '2001', password: 's', server: 'pbx.example.com'),
        campaignId: 'INBOUND',
        campaignName: 'Inbound support',
        queueIds: const ['DID_INBOUND', 'P1_INBOUND'],
      );
      final back = Session.fromJson(s.toJson())!;
      expect(back.hasShift, isTrue);
      expect(back.queueIds, ['DID_INBOUND', 'P1_INBOUND']);
      expect(back.sip?.server, 'pbx.example.com');
    });

    test('a renewal keeps the shift the agent already picked', () {
      final mine = Session(
        slug: 'v',
        user: '1',
        password: 'p',
        expiresAt: DateTime.utc(2026),
        campaignId: 'INBOUND',
        queueIds: const ['A'],
      );
      final fresh = Session(slug: 'v', user: '1', password: 'p', expiresAt: DateTime.utc(2027));
      final merged = mine.renewedFrom(fresh);
      expect(merged.campaignId, 'INBOUND');
      expect(merged.queueIds, ['A']);
      expect(merged.expiresAt, DateTime.utc(2027));
    });
  });

  group('caller number from the INVITE', () {
    SipCall call(String? display, String? uri) =>
        SipCall(callId: '1', remoteUri: uri, remoteDisplay: display, incoming: true, state: CallState.incoming);

    test(
      'RA_AGENT_PHONE on-hook caller ID',
      () => expect(call('RA_2001_3055550142', 'sip:3055550142@192.0.2.10').phoneHint, '3055550142'),
    );
    test('CUSTOMER_PHONE_RINGAGENT', () => expect(call('RINGAGENT_3055550142', 'sip:x@h').phoneHint, '3055550142'));
    test(
      'generic RINGAGENT falls back to the URI number',
      () => expect(call('RINGAGENT00000012345', 'sip:3055550142@h').phoneHint, '3055550142'),
    );
    test(
      'VICIdial tracking ID is never shown',
      () => expect(call('Y5223441100000000016', 'sip:Y5223441100000000016@h').phoneHint, ''),
    );
  });

  group('call states', () {
    test('states the app does not act on neither start nor end a call', () {
      for (final raw in ['EarlyUpdatedByRemote', 'EarlyUpdating', 'Referred', 'PushIncomingReceived']) {
        expect(CallState.parse(raw), CallState.other, reason: raw);
        expect(CallState.parse(raw).isOver, isFalse, reason: raw);
      }
      expect(CallState.parse('Released').isOver, isTrue);
      expect(CallState.parse('Error').isOver, isTrue);
      expect(CallState.parse('Idle').isOver, isFalse);
    });

    test('a re-register from a working line keeps the line up', () {
      const ok = LineState(reg: RegState.ok);
      expect(ok.withReg(RegState.progress).up, isTrue);
      expect(ok.withReg(RegState.progress).withReg(RegState.failed).up, isFalse);
      expect(const LineState().withReg(RegState.progress).up, isFalse);
    });
  });

  group('plain-language errors', () {
    test('every server code reaches a message, case-insensitively', () {
      expect(AppError.parseReason('no_active_session'), AppErrorCode.sessionEnded);
      expect(AppError.parseReason('box_unreachable'), AppErrorCode.phoneSystemDown);
      expect(AppError.parseReason('APP_NOT_SUBSCRIBED'), AppErrorCode.appNotSubscribed);
      expect(AppError.parseReason('stats_disabled'), AppErrorCode.featureOff);
      expect(AppError.parseReason('something_new'), AppErrorCode.unknown);
    });

    test('messages never leak codes', () {
      for (final code in AppErrorCode.values) {
        final m = AppError(code).message;
        expect(m, isNot(contains('_')), reason: '$code');
        expect(m.trim(), isNotEmpty);
      }
    });

    test('only the right errors send the agent back to sign-in', () {
      expect(const AppError(AppErrorCode.signedInElsewhere).endsSession, isTrue);
      expect(const AppError(AppErrorCode.phoneSystemDown).endsSession, isFalse);
    });
  });

  group('callback note', () {
    test('is cut to the server\'s 200 UTF-16 units without splitting an emoji', () {
      expect(fitUtf16('short', 200), 'short');
      final emoji = '😀' * 150; // 300 UTF-16 units
      final cut = fitUtf16(emoji, 200);
      expect(cut.length, 200);
      expect(cut.runes.every((r) => r == 0x1F600), isTrue);
      expect(fitUtf16('a${'😀' * 100}', 200).length, 199);
    });
  });

  group('updates', () {
    test('only a higher X.Y.Z counts as newer', () {
      expect(isNewer('1.0.1', '1.0.0'), isTrue);
      expect(isNewer('1.1.0', '1.0.9'), isTrue);
      expect(isNewer('1.0.0', '1.0.0+120'), isFalse);
      expect(isNewer('0.9.9', '1.0.0'), isFalse);
      expect(isNewer('1.0.0', '1.0.0 (100)'), isFalse);
    });
  });

  group('format', () {
    test('timers', () {
      expect(clock(const Duration(seconds: 7)), '0:07');
      expect(clock(const Duration(minutes: 4, seconds: 26)), '4:26');
      expect(clock(const Duration(hours: 1, minutes: 2, seconds: 9)), '1:02:09');
      expect(span(const Duration(hours: 1, minutes: 42)), '1h 42m');
      expect(span(const Duration(minutes: 31)), '31m');
      expect(talk(const Duration(minutes: 4, seconds: 26)), '4m 26s');
      expect(talk(const Duration(seconds: 38)), '38s');
      expect(talk(const Duration(minutes: 3)), '3m');
      expect(talk(const Duration(hours: 1, minutes: 2, seconds: 9)), '1h 2m');
    });

    test('times of day follow the phone\'s 24-hour setting', () {
      final t = DateTime(2026, 10, 9, 14, 5);
      expect(timeOfDay(t), '2:05\u202fPM');
      expect(timeOfDay(t, h24: true), '14:05');
    });

    test('phone numbers', () {
      expect(phone('3055550142'), '(305) 555-0142');
      expect(phone('13055550142'), '(305) 555-0142');
      expect(phone('+442071234567'), '+442071234567');
    });

    test("a customer's local time from VICIdial's offset", () {
      final local = localTimeAt(-4, now: DateTime.utc(2026, 10, 9, 14, 14));
      expect(local?.hour, 10);
      expect(local?.minute, 14);
    });
  });
}
