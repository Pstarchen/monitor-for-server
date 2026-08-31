export type ApiTokenScopeOption = readonly [value: string, label: string]

export interface ApiTokenScopeGroup {
  readonly key: string
  readonly label: string
  readonly description: string
  readonly options: readonly ApiTokenScopeOption[]
}

const ADMIN_SCOPE = 'nezha:admin:*'

export const apiTokenScopeGroups: readonly ApiTokenScopeGroup[] = [
  {
    key: 'inventory', label: '设备清单', description: '查看设备列表或删除设备。',
    options: [
      ['nezha:inventory:read', '设备清单读取'],
      ['nezha:inventory:delete', '设备删除'],
    ],
  },
  {
    key: 'server', label: '服务器', description: '读取指标，或执行配置与远程任务。',
    options: [
      ['nezha:server:read', '设备指标读取'],
      ['nezha:server:write', '设备配置写入'],
      ['nezha:server:delete', '远程文件删除'],
      ['nezha:server:exec', '远程任务执行'],
    ],
  },
  {
    key: 'service', label: '服务监控', description: '查看或维护 HTTP、TCP 和 Ping 检查。',
    options: [
      ['nezha:service:read', '服务监控读取'],
      ['nezha:service:write', '服务监控写入'],
      ['nezha:service:delete', '服务监控删除'],
    ],
  },
  {
    key: 'ddns', label: 'DDNS', description: '读取或维护动态域名解析配置。',
    options: [
      ['nezha:ddns:read', 'DDNS 配置读取'],
      ['nezha:ddns:write', 'DDNS 配置写入'],
      ['nezha:ddns:delete', 'DDNS 配置删除'],
    ],
  },
  {
    key: 'alertrule', label: '告警规则', description: '查看或维护触发条件与阈值。',
    options: [
      ['nezha:alertrule:read', '告警规则读取'],
      ['nezha:alertrule:write', '告警规则写入'],
      ['nezha:alertrule:delete', '告警规则删除'],
    ],
  },
  {
    key: 'alert', label: '告警事件', description: '查看告警，或执行确认与恢复操作。',
    options: [
      ['nezha:alert:read', '告警读取'],
      ['nezha:alert:write', '告警处理'],
    ],
  },
  {
    key: 'maintenance', label: '维护静默', description: '查看或维护告警静默窗口。',
    options: [
      ['nezha:maintenance:read', '维护窗口读取'],
      ['nezha:maintenance:write', '维护窗口写入'],
      ['nezha:maintenance:delete', '维护窗口删除'],
    ],
  },
  {
    key: 'admin', label: '管理员', description: '完整管理权限，仅管理员可签发。',
    options: [[ADMIN_SCOPE, '管理员权限']],
  },
]

export const apiTokenScopeOptions: readonly ApiTokenScopeOption[] = apiTokenScopeGroups.flatMap((group) => group.options)

export const defaultApiTokenScopes = ['nezha:inventory:read', 'nezha:server:read', 'nezha:alert:read'] as const

export function visibleApiTokenScopes(isAdmin: boolean): readonly ApiTokenScopeOption[] {
  return isAdmin ? apiTokenScopeOptions : apiTokenScopeOptions.filter(([value]) => value !== ADMIN_SCOPE)
}

export function visibleApiTokenScopeGroups(isAdmin: boolean): readonly ApiTokenScopeGroup[] {
  return isAdmin ? apiTokenScopeGroups : apiTokenScopeGroups.filter((group) => group.key !== 'admin')
}

const scopeLabels = new Map(apiTokenScopeOptions)

export function apiTokenScopeLabel(scope: string): string {
  return scopeLabels.get(scope) ?? scope
}
