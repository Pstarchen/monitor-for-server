export type ApiTokenScopeOption = readonly [value: string, label: string]

const ADMIN_SCOPE = 'nezha:admin:*'

export const apiTokenScopeOptions: readonly ApiTokenScopeOption[] = [
  ['nezha:inventory:read', '设备清单读取'],
  ['nezha:inventory:delete', '设备删除'],
  ['nezha:server:read', '设备指标读取'],
  ['nezha:server:write', '设备配置写入'],
  ['nezha:server:delete', '远程文件删除'],
  ['nezha:server:exec', '远程任务执行'],
  ['nezha:service:read', '服务监控读取'],
  ['nezha:service:write', '服务监控写入'],
  ['nezha:service:delete', '服务监控删除'],
  ['nezha:ddns:read', 'DDNS 配置读取'],
  ['nezha:ddns:write', 'DDNS 配置写入'],
  ['nezha:ddns:delete', 'DDNS 配置删除'],
  ['nezha:alertrule:read', '告警规则读取'],
  ['nezha:alertrule:write', '告警规则写入'],
  ['nezha:alertrule:delete', '告警规则删除'],
  ['nezha:alert:read', '告警读取'],
  ['nezha:alert:write', '告警处理'],
  [ADMIN_SCOPE, '管理员权限'],
]

export function visibleApiTokenScopes(isAdmin: boolean): readonly ApiTokenScopeOption[] {
  return isAdmin ? apiTokenScopeOptions : apiTokenScopeOptions.filter(([value]) => value !== ADMIN_SCOPE)
}
