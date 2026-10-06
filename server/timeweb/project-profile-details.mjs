// Pure initial-import projection. The original typed fields and timestamp are
// never modified; fields which cannot fit the existing schema fail the plan.
export const PROFILE_DETAILS_COLUMNS = Object.freeze([
  'age', 'height_cm', 'about_text', 'interests_text', 'has_children', 'gender',
  'relationship_status', 'country_code', 'region', 'language_code',
  'secondary_group', 'profile_details_saved', 'registration_complete',
]);

export class ProfileDetailsProjectionError extends Error {
  constructor(field, reason) {
    super(`Profile details ${field}: ${reason}`);
    this.name = 'ProfileDetailsProjectionError';
    this.field = field;
    this.reason = reason;
  }
}

const fail = (field, reason) => { throw new ProfileDetailsProjectionError(field, reason); };
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

function typed(fields, name) {
  if (!Object.hasOwn(fields, name)) return null;
  const value = fields[name];
  if (!object(value) || Object.keys(value).length !== 1) fail(name, 'invalid_typed_field');
  return Object.hasOwn(value, 'nullValue') ? null : value;
}

function string(fields, name, maximum, schemaMaximum = maximum) {
  const source = typed(fields, name);
  if (source === null) return null;
  if (!Object.hasOwn(source, 'stringValue') || typeof source.stringValue !== 'string') {
    fail(name, 'expected_string');
  }
  const value = source.stringValue;
  const characters = [...value];
  if (characters.some((char) => char.codePointAt(0) >= 0xd800 && char.codePointAt(0) <= 0xdfff)) {
    fail(name, 'invalid_utf8');
  }
  if (characters.length > schemaMaximum || Buffer.byteLength(value, 'utf8') > schemaMaximum * 4) {
    fail(name, 'schema_string_bound');
  }
  if (characters.length > maximum) fail(name, 'source_string_bound');
  return value; // No trim, alias, Unicode normalization or invented content.
}

function age(fields) {
  const source = typed(fields, 'age');
  if (source === null) return null;
  let number;
  if (Object.hasOwn(source, 'doubleValue')) {
    number = source.doubleValue;
    if (typeof number !== 'number' || !Number.isFinite(number)) fail('age', 'expected_finite_number');
  } else {
    const raw = source.integerValue ?? source.stringValue;
    if (!(Object.hasOwn(source, 'integerValue') || Object.hasOwn(source, 'stringValue'))
        || typeof raw !== 'string' || raw.length < 1 || raw.length > 3
        || /[^0-9]/.test(raw)) fail('age', 'expected_integer_digits');
    number = Number(raw);
  }
  if (number < 0 || number > 130) fail('age', 'schema_integer_range');
  if (!Number.isInteger(number)) fail('age', 'fractional_number');
  return number;
}

function height(fields) {
  const value = string(fields, 'rost', 191);
  if (value === null) return null;
  if (!value || /[^0-9]/.test(value)) fail('rost', 'expected_integer_string');
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number > 300) fail('rost', 'schema_integer_range');
  return number;
}

function boolean(fields, name, { required = false } = {}) {
  if (!Object.hasOwn(fields, name)) return required ? 0 : null;
  const source = typed(fields, name);
  if (source === null) {
    if (required) fail(name, 'schema_not_nullable');
    return null;
  }
  if (!Object.hasOwn(source, 'booleanValue') || typeof source.booleanValue !== 'boolean') {
    fail(name, 'expected_boolean');
  }
  return source.booleanValue ? 1 : 0;
}

export function projectProfileDetails(fields) {
  if (!object(fields)) fail('fields', 'expected_object');
  return {
    age: age(fields), height_cm: height(fields),
    about_text: string(fields, 'about', 4096), interests_text: string(fields, 'hobbi', 4096),
    has_children: boolean(fields, 'deti'), gender: string(fields, 'pol', 191),
    relationship_status: string(fields, 'relationStatus', 191),
    country_code: string(fields, 'countryCode', 20, 191), region: string(fields, 'region', 1000, 191),
    language_code: string(fields, 'languageCode', 191), secondary_group: string(fields, 'secondaryGroup', 191),
    profile_details_saved: boolean(fields, 'profileDetailsSaved', { required: true }),
    registration_complete: boolean(fields, 'isRegistrationEnd', { required: true }),
  };
}
