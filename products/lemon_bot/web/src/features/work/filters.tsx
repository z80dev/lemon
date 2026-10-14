import { useId, useState } from 'react';
import type { JSONObject, JSONValue } from '@lemon-bot/sdk';
import { Field } from '../../ui';

function resolveSchema(schema: JSONObject, root: JSONObject): JSONObject {
  if (typeof schema.$ref !== 'string') return schema;
  if (!schema.$ref.startsWith('#/')) return {};
  let resolved: JSONValue = root;
  for (const part of schema.$ref.slice(2).split('/')) {
    if (resolved === null || typeof resolved !== 'object' || Array.isArray(resolved)) return {};
    resolved = resolved[part.replaceAll('~1', '/').replaceAll('~0', '~')];
  }
  return resolved && typeof resolved === 'object' && !Array.isArray(resolved) ? resolved : {};
}

export function filterErrors(schema: JSONObject, value: JSONValue, root = schema, path = 'Filters', depth = 0): string[] {
  if (depth > 20) return [`${path}: filter nesting is too deep.`];
  schema = resolveSchema(schema, root);
  if (Array.isArray(schema.allOf)) return schema.allOf.flatMap(item => item && typeof item === 'object' && !Array.isArray(item) ? filterErrors(item, value, root, path, depth + 1) : [`${path}: unsupported schema.`]);
  const variants = schema.oneOf ?? schema.anyOf;
  if (Array.isArray(variants)) {
    const valid = variants.filter(item => item && typeof item === 'object' && !Array.isArray(item) && !filterErrors(item, value, root, path, depth + 1).length);
    if (schema.oneOf ? valid.length !== 1 : !valid.length) return [`${path}: select values matching the provider's allowed variant.`];
  }
  if ('const' in schema && JSON.stringify(value) !== JSON.stringify(schema.const)) return [`${path}: value must match the provider constant.`];
  if (Array.isArray(schema.enum) && !schema.enum.some(item => JSON.stringify(item) === JSON.stringify(value))) return [`${path}: choose an advertised value.`];
  if (Array.isArray(schema.type)) {
    if (!schema.type.some(type => typeof type === 'string' && !filterErrors({ ...schema, type }, value, root, path, depth + 1).length)) return [`${path}: wrong value type.`];
    return [];
  }
  const errors: string[] = [];
  switch (schema.type) {
    case 'object': {
      if (value === null || typeof value !== 'object' || Array.isArray(value)) return [`${path}: an object is required.`];
      const properties = schema.properties && typeof schema.properties === 'object' && !Array.isArray(schema.properties) ? schema.properties : {};
      for (const required of Array.isArray(schema.required) ? schema.required : []) if (typeof required === 'string' && !(required in value)) errors.push(`${path}.${required}: required.`);
      for (const [key, child] of Object.entries(value)) {
        const definition = properties[key];
        if (definition && typeof definition === 'object' && !Array.isArray(definition)) errors.push(...filterErrors(definition, child, root, `${path}.${key}`, depth + 1));
        else if (schema.additionalProperties === false) errors.push(`${path}.${key}: not supported by this event.`);
      }
      break;
    }
    case 'array': {
      if (!Array.isArray(value)) return [`${path}: a list is required.`];
      if (typeof schema.minItems === 'number' && value.length < schema.minItems) errors.push(`${path}: at least ${schema.minItems} values required.`);
      if (typeof schema.maxItems === 'number' && value.length > schema.maxItems) errors.push(`${path}: at most ${schema.maxItems} values allowed.`);
      if (schema.uniqueItems && new Set(value.map(item => JSON.stringify(item))).size !== value.length) errors.push(`${path}: duplicate values are not allowed.`);
      if (schema.items && typeof schema.items === 'object' && !Array.isArray(schema.items)) value.forEach((child, index) => errors.push(...filterErrors(schema.items as JSONObject, child, root, `${path}[${index + 1}]`, depth + 1)));
      break;
    }
    case 'string':
      if (typeof value !== 'string') return [`${path}: text is required.`];
      if (typeof schema.minLength === 'number' && value.length < schema.minLength) errors.push(`${path}: minimum length ${schema.minLength}.`);
      if (typeof schema.maxLength === 'number' && value.length > schema.maxLength) errors.push(`${path}: maximum length ${schema.maxLength}.`);
      if (typeof schema.pattern === 'string') { try { if (!new RegExp(schema.pattern).test(value)) errors.push(`${path}: does not match the provider's required pattern.`); } catch { errors.push(`${path}: provider pattern is invalid.`); } }
      break;
    case 'number': case 'integer':
      if (typeof value !== 'number' || !Number.isFinite(value) || (schema.type === 'integer' && !Number.isInteger(value))) return [`${path}: a finite ${schema.type} is required.`];
      if (typeof schema.minimum === 'number' && value < schema.minimum) errors.push(`${path}: minimum ${schema.minimum}.`);
      if (typeof schema.maximum === 'number' && value > schema.maximum) errors.push(`${path}: maximum ${schema.maximum}.`);
      if (typeof schema.exclusiveMinimum === 'number' && value <= schema.exclusiveMinimum) errors.push(`${path}: must exceed ${schema.exclusiveMinimum}.`);
      if (typeof schema.exclusiveMaximum === 'number' && value >= schema.exclusiveMaximum) errors.push(`${path}: must be below ${schema.exclusiveMaximum}.`);
      break;
    case 'boolean': if (typeof value !== 'boolean') errors.push(`${path}: true or false required.`); break;
    case 'null': if (value !== null) errors.push(`${path}: null required.`); break;
  }
  return errors;
}

export function SchemaFilters({ schema, value, onChange }: { schema: JSONObject; value: JSONObject; onChange: (value: JSONObject) => void }) {
  return <fieldset className="stack"><legend>Exact provider event filters</legend><SchemaValue schema={schema} root={schema} label="Filters" value={value} onChange={next => { if (next && typeof next === 'object' && !Array.isArray(next)) onChange(next); }} depth={0} /></fieldset>;
}

function SchemaValue({ schema, root, label, value, onChange, depth }: { schema: JSONObject; root: JSONObject; label: string; value: JSONValue | undefined; onChange: (value: JSONValue) => void; depth: number }) {
  const id = useId();
  const [variantIndex, setVariantIndex] = useState(-1);
  if (depth > 20) return <p role="alert">Provider filter nesting exceeds the safe editor depth.</p>;
  schema = resolveSchema(schema, root);
  const variants = schema.oneOf ?? schema.anyOf ?? (Array.isArray(schema.type) ? schema.type.map(type => ({ ...schema, type })) : undefined);
  if (Array.isArray(variants)) {
    const options = variants.filter((item): item is JSONObject => !!item && typeof item === 'object' && !Array.isArray(item));
    const selected = variantIndex >= 0 && variantIndex < options.length ? variantIndex : options.findIndex(item => value !== undefined && !filterErrors(item, value, root).length);
    return <div className="stack">
      <Field label={`${label} variant`}><select value={selected < 0 ? '' : selected} onChange={event => {
        if (event.target.value === '') { setVariantIndex(-1); return; }
        const index = Number(event.target.value);
        const option = options[index];
        if (!option) return;
        setVariantIndex(index);
        onChange(option.default ?? option.const ?? (option.type === 'object' ? {} : option.type === 'array' ? [] : option.type === 'null' ? null : option.type === 'number' || option.type === 'integer' ? 0 : option.type === 'boolean' ? false : ''));
      }}><option value="">Choose provider variant</option>{options.map((option, index) => <option key={index} value={index}>{typeof option.title === 'string' ? option.title : `Variant ${index + 1}`}</option>)}</select></Field>
      {selected >= 0 && <SchemaValue schema={options[selected]} root={root} label={label} value={value} onChange={onChange} depth={depth + 1} />}
    </div>;
  }
  if ('const' in schema) return <Field label={label}><button type="button" onClick={() => onChange(schema.const)}>Use required value: {JSON.stringify(schema.const)}</button></Field>;
  if (Array.isArray(schema.enum)) return <Field label={label} hint={typeof schema.description === 'string' ? schema.description : undefined}><select value={schema.enum.findIndex(item => JSON.stringify(item) === JSON.stringify(value))} onChange={event => { const index = Number(event.target.value); if (Array.isArray(schema.enum) && index >= 0 && index < schema.enum.length) onChange(schema.enum[index]); }}><option value={-1}>Choose advertised value</option>{schema.enum.map((item, index) => <option key={index} value={index}>{typeof item === 'string' ? item : JSON.stringify(item)}</option>)}</select></Field>;
  if (schema.type === 'object') {
    const object = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
    const properties = schema.properties && typeof schema.properties === 'object' && !Array.isArray(schema.properties) ? schema.properties : {};
    return <fieldset className="stack"><legend>{label}</legend>{Object.entries(properties).map(([key, definition]) => {
      if (!definition || typeof definition !== 'object' || Array.isArray(definition)) return null;
      const required = Array.isArray(schema.required) && schema.required.includes(key);
      return <div className="card stack" key={key}>{!required && <label className="row"><input type="checkbox" checked={key in object} onChange={event => { const next = { ...object }; if (event.target.checked) next[key] = definition.default ?? (definition.type === 'object' ? {} : definition.type === 'array' ? [] : definition.type === 'boolean' ? false : definition.type === 'number' || definition.type === 'integer' ? 0 : ''); else delete next[key]; onChange(next); }} />Include {key}</label>}{(required || key in object) && <SchemaValue schema={definition} root={root} label={`${typeof definition.title === 'string' ? definition.title : key}${required ? ' (required)' : ''}`} value={object[key]} onChange={next => onChange({ ...object, [key]: next })} depth={depth + 1} />}</div>;
    })}{Object.keys(object).filter(key => !(key in properties)).map(key => <div className="error-notice" key={key}><p>Existing unsupported field: {key}</p><button type="button" onClick={() => { const next = { ...object }; delete next[key]; onChange(next); }}>Remove unsupported field</button></div>)}</fieldset>;
  }
  if (schema.type === 'array') {
    const values = Array.isArray(value) ? value : [];
    const itemSchema = schema.items && typeof schema.items === 'object' && !Array.isArray(schema.items) ? schema.items : null;
    if (!itemSchema) return <p role="alert">Provider did not advertise a supported item schema for {label}.</p>;
    return <fieldset className="stack"><legend>{label}</legend>{values.map((item, index) => <div className="row" key={index}><SchemaValue schema={itemSchema} root={root} label={`${label} ${index + 1}`} value={item} onChange={next => onChange(values.map((old, i) => i === index ? next : old))} depth={depth + 1} /><button type="button" onClick={() => onChange(values.filter((_, i) => i !== index))}>Remove value {index + 1}</button></div>)}<button type="button" disabled={typeof schema.maxItems === 'number' && values.length >= schema.maxItems} onClick={() => onChange([...values, itemSchema.default ?? (itemSchema.type === 'object' ? {} : itemSchema.type === 'boolean' ? false : itemSchema.type === 'number' || itemSchema.type === 'integer' ? 0 : '')])}>Add {label} value</button></fieldset>;
  }
  const hint = typeof schema.description === 'string' ? schema.description : undefined;
  if (schema.type === 'boolean') return <Field label={label} hint={hint}><select value={typeof value === 'boolean' ? String(value) : ''} onChange={event => onChange(event.target.value === 'true')}><option value="">Choose</option><option value="true">True</option><option value="false">False</option></select></Field>;
  if (schema.type === 'null') return <Field label={label}><button type="button" onClick={() => onChange(null)}>Set null</button></Field>;
  if (schema.type === 'string' || schema.type === 'number' || schema.type === 'integer') return <Field label={label} hint={hint}><input id={id} type={schema.type === 'string' ? 'text' : 'number'} step={schema.type === 'integer' ? 1 : 'any'} min={typeof schema.minimum === 'number' ? schema.minimum : undefined} max={typeof schema.maximum === 'number' ? schema.maximum : undefined} minLength={typeof schema.minLength === 'number' ? schema.minLength : undefined} maxLength={typeof schema.maxLength === 'number' ? schema.maxLength : undefined} pattern={typeof schema.pattern === 'string' ? schema.pattern : undefined} value={typeof value === 'string' || typeof value === 'number' ? value : ''} onChange={event => onChange(schema.type === 'string' ? event.target.value : event.target.value === '' ? null : Number(event.target.value))} /></Field>;
  return <p role="alert">The provider's {label} schema does not expose a supported typed field. Choose another supported event or ask the operator to correct its schema.</p>;
}
