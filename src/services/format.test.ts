import { describe, expect, it } from 'vitest';
import { formatBytes, formatDuration, formatSpeed, parseDeviceSize, percentOf } from './format';

describe('formatBytes', () => {
  it('usa la unidad que hace legible la cifra', () => {
    expect(formatBytes(0)).toBe('0 B');
    expect(formatBytes(512)).toBe('512 B');
    expect(formatBytes(1024)).toBe('1,0 KB');
    expect(formatBytes(1024 * 1024)).toBe('1,0 MB');
    expect(formatBytes(2.5 * 1024 * 1024 * 1024)).toBe('2,5 GB');
  });

  it('no inventa precisión en los bytes sueltos', () => {
    expect(formatBytes(999)).toBe('999 B');
  });
});

describe('formatSpeed', () => {
  it('muestra MB/s con un decimal', () => {
    expect(formatSpeed(12.345)).toBe('12,3 MB/s');
    expect(formatSpeed(0)).toBe('0,0 MB/s');
  });
});

describe('formatDuration', () => {
  it('escribe minutos y segundos, no solo segundos', () => {
    expect(formatDuration(45)).toBe('45 s');
    expect(formatDuration(75)).toBe('1 min 15 s');
    expect(formatDuration(3600)).toBe('1 h 0 min');
    expect(formatDuration(3725)).toBe('1 h 2 min');
  });

  it('no promete un tiempo que no conoce', () => {
    expect(formatDuration(0)).toBe('—');
    expect(formatDuration(Number.POSITIVE_INFINITY)).toBe('—');
    expect(formatDuration(Number.NaN)).toBe('—');
    expect(formatDuration(-5)).toBe('—');
  });
});

describe('percentOf', () => {
  it('acota entre 0 y 100', () => {
    expect(percentOf(0, 100)).toBe(0);
    expect(percentOf(50, 100)).toBe(50);
    expect(percentOf(150, 100)).toBe(100);
    expect(percentOf(-5, 100)).toBe(0);
  });

  it('devuelve 0 cuando el total todavía no se conoce', () => {
    expect(percentOf(10, 0)).toBe(0);
  });
});

describe('parseDeviceSize', () => {
  it('interpreta GB y MB con punto o coma decimal', () => {
    expect(parseDeviceSize('29.74 GB')).toBeCloseTo(29.74 * 1024 ** 3);
    expect(parseDeviceSize('29,74 GB')).toBeCloseTo(29.74 * 1024 ** 3);
    expect(parseDeviceSize('512.00 MB')).toBeCloseTo(512 * 1024 ** 2);
  });

  it('devuelve null ante un formato que no reconoce', () => {
    expect(parseDeviceSize('desconocido')).toBeNull();
    expect(parseDeviceSize('')).toBeNull();
  });
});
