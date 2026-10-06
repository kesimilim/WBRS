import assert from 'node:assert/strict';
import test from 'node:test';
import { PROFILE_DETAILS_COLUMNS, ProfileDetailsProjectionError, projectProfileDetails } from '../project-profile-details.mjs';

const s = (stringValue) => ({ stringValue });
const b = (booleanValue) => ({ booleanValue });
const n = { nullValue: null };

test('profile details retain exact source text, nullable data, direct keys and boolean distinctions', () => {
  const fields = { age: { integerValue: '028' }, rost: s('000180'), about: s(' \tКоротко\n '),
    hobbi: s(''), deti: b(false), pol: s(' мужской '), relationStatus: s('свободен'),
    countryCode: s('ru'), region: s(' Регион '), languageCode: s('ru'), secondaryGroup: s('Синяя'),
    profileDetailsSaved: b(true), isRegistrationEnd: b(false),
    balance: { integerValue: '9007199254740993' }, isUnVisible: b(true),
    unvisibleEnd: { timestampValue: '2027-01-01T00:00:00Z' }, status: s('blocked') };
  const before = structuredClone(fields);
  const row = projectProfileDetails(fields);
  assert.deepEqual(row, { age: 28, height_cm: 180, about_text: ' \tКоротко\n ', interests_text: '',
    has_children: 0, gender: ' мужской ', relationship_status: 'свободен', country_code: 'ru',
    region: ' Регион ', language_code: 'ru', secondary_group: 'Синяя',
    profile_details_saved: 1, registration_complete: 0 });
  assert.deepEqual(Object.keys(row), PROFILE_DETAILS_COLUMNS);
  assert.deepEqual(fields, before);
  assert.deepEqual(projectProfileDetails({ languageGroup: s('Russian'), language: s('ru'),
    city: s('No region alias'), group: s('No secondary alias'), 'группа': s('бело-красная') }),
    Object.fromEntries(PROFILE_DETAILS_COLUMNS.map((column) => [column,
      ['profile_details_saved', 'registration_complete'].includes(column) ? 0 : null])));
  const nullable = Object.fromEntries(['age', 'rost', 'about', 'hobbi', 'deti', 'pol',
    'relationStatus', 'countryCode', 'region', 'languageCode', 'secondaryGroup'].map((key) => [key, n]));
  assert.deepEqual(projectProfileDetails(nullable), projectProfileDetails({}));
  assert.equal(projectProfileDetails({ deti: b(true) }).has_children, 1);
  assert.equal(projectProfileDetails({ deti: n }).has_children, null);
});

test('legacy integer/string/integral double ages fit existing INT without rounding or source changes', () => {
  for (const [source, expected] of [[{ integerValue: '000' }, 0], [{ stringValue: '130' }, 130],
    [{ doubleValue: 28 }, 28], [{ doubleValue: 130.0 }, 130]]) {
    assert.equal(projectProfileDetails({ age: source }).age, expected);
  }
  assert.equal(projectProfileDetails({ rost: s('0') }).height_cm, 0);
  assert.equal(projectProfileDetails({ rost: s('300') }).height_cm, 300);
});

test('incompatible historical values refuse per field and reason without printing source content', () => {
  const cases = [
    ['age', { integerValue: '150' }, 'schema_integer_range'],
    ['age', { doubleValue: 28.5 }, 'fractional_number'],
    ['age', { doubleValue: -1 }, 'schema_integer_range'],
    ['age', { doubleValue: Infinity }, 'expected_finite_number'],
    ['age', { doubleValue: 'NaN' }, 'expected_finite_number'],
    ['age', { integerValue: 28 }, 'expected_integer_digits'],
    ['age', s('28\n'), 'expected_integer_digits'],
    ['rost', s('180 см'), 'expected_integer_string'],
    ['rost', s('180.5'), 'expected_integer_string'],
    ['rost', s('180\n'), 'expected_integer_string'],
    ['rost', s(''), 'expected_integer_string'],
    ['rost', s('301'), 'schema_integer_range'],
    ['rost', { integerValue: '180' }, 'expected_string'],
    ['region', s('😀'.repeat(192)), 'schema_string_bound'],
    ['profileDetailsSaved', n, 'schema_not_nullable'],
    ['isRegistrationEnd', n, 'schema_not_nullable'],
    ['deti', b('true'), 'expected_boolean'],
    ['about', s(null), 'expected_string'],
    ['pol', { stringValue: 'male', nullValue: null }, 'invalid_typed_field'],
    ['hobbi', s('\ud800'), 'invalid_utf8'],
  ];
  for (const [field, value, reason] of cases) {
    assert.throws(() => projectProfileDetails({ [field]: value }), (error) => {
      assert.ok(error instanceof ProfileDetailsProjectionError);
      assert.equal(error.field, field); assert.equal(error.reason, reason);
      assert.equal(error.message, `Profile details ${field}: ${reason}`);
      return true;
    });
  }
});

test('string bounds count Unicode code points and retain whitespace and nullable flags exactly', () => {
  assert.equal(projectProfileDetails({ region: s('😀'.repeat(191)) }).region, '😀'.repeat(191));
  assert.equal(projectProfileDetails({ about: s('😀'.repeat(4096)) }).about_text, '😀'.repeat(4096));
  assert.throws(() => projectProfileDetails({ about: s('😀'.repeat(4097)) }), /about: schema_string_bound/);
  assert.throws(() => projectProfileDetails({ countryCode: s('x'.repeat(21)) }), /countryCode: source_string_bound/);
  assert.throws(() => projectProfileDetails({ age: { stringValue: '28', integerValue: '28' } }), /invalid_typed_field/);
  assert.throws(() => projectProfileDetails([]), /fields: expected_object/);
});
