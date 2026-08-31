import { describe, expect, it } from 'vitest'
import { csvCell, toCsv } from './csv'

describe('csv helpers', () => {
  it('escapes commas, quotes and line breaks', () => {
    expect(csvCell('a,"b"\nc')).toBe('"a,""b""\nc"')
  })

  it('emits a stable UTF-8 friendly table body', () => {
    expect(toCsv(['名称', '状态'], [['API', '在线'], ['空值', null]])).toBe('名称,状态\r\nAPI,在线\r\n空值,\r\n')
  })
})
