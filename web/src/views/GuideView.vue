<script setup lang="ts">
import { computed, ref, type Component } from 'vue'
import {
  Activity, Archive, ArrowRight, BarChart3, BellRing, BookOpen, CalendarClock, CircleGauge, ClipboardList,
  GitBranch, Globe2, KeyRound, Lightbulb, ListChecks, LockKeyhole, MousePointerClick, Radar,
  Rocket, Search, Server, Settings, ShieldCheck, SlidersHorizontal, Terminal, Users,
  Smartphone,
} from 'lucide-vue-next'
import PageHeader from '@/components/PageHeader.vue'
import EmptyState from '@/components/EmptyState.vue'
import { useAuthStore } from '@/stores/auth'
import type { Role } from '@/types'

type GuideCategory = '监控入门' | '告警响应' | '自动化运维' | '系统管理'

interface GuideTopic {
  id: string
  category: GuideCategory
  title: string
  summary: string
  route?: string
  entry: string
  access: string
  roles?: Role[]
  icon: Component
  steps: string[]
  note: string
  keywords?: string[]
}

interface QuickStartStep {
  title: string
  description: string
  route: string
  roles: Role[]
}

const auth = useAuthStore()
const keyword = ref('')
const category = ref<'全部' | GuideCategory>('全部')

const roleNames: Record<Role, string> = {
  ADMIN: '管理员',
  OPERATOR: '运维人员',
  VIEWER: '只读用户',
}

const categoryOptions = ['全部', '监控入门', '告警响应', '自动化运维', '系统管理'].map((value) => ({ label: value, value }))

const quickStart: QuickStartStep[] = [
  { title: '登记第一台设备', description: '在设备管理中创建节点，填写名称、分组和资产信息。', route: '/devices', roles: ['ADMIN', 'OPERATOR'] },
  { title: '完成 Agent 接入', description: '立即保存一次性密钥或安装命令，在目标服务器运行并等待首次上报。', route: '/devices', roles: ['ADMIN', 'OPERATOR'] },
  { title: '补充服务与告警', description: '创建服务探测和资源告警规则，确认阈值与失败次数符合值班要求。', route: '/services', roles: ['ADMIN', 'OPERATOR'] },
  { title: '配置通知与恢复点', description: '管理员测试通知通道并创建数据库备份，形成完整的响应闭环。', route: '/settings', roles: ['ADMIN'] },
]

const topics: GuideTopic[] = [
  {
    id: 'dashboard', category: '监控入门', title: '运行总览', icon: CircleGauge, route: '/dashboard', entry: '左侧导航 → 运行总览',
    access: '所有账号，数据按设备权限显示',
    summary: '快速判断节点在线率、资源压力、活动告警和近期值班记录。',
    steps: [
      '先查看顶部设备、在线、活动告警和安全指标，确认是否存在需要立即处理的异常。',
      '在资源趋势中选择最多 4 台节点，并切换 1、6 或 24 小时范围比较资源尖峰。',
      '点击值班记录或设备入口进入详情，继续查看主机、进程、容器和安全巡检。',
    ],
    note: '离线数量增加或指标长时间不更新时，优先检查 Agent 服务、网络和设备详情中的接入诊断。',
    keywords: ['首页', '趋势', '在线率', '值班记录'],
  },
  {
    id: 'devices', category: '监控入门', title: '设备管理与 Agent 接入', icon: Server, route: '/devices', entry: '左侧导航 → 设备管理',
    access: '查看：所有账号；新增与编辑：管理员或运维人员',
    summary: '登记服务器、维护资产归属，并生成 Agent 接入凭据。',
    steps: [
      '点击“添加设备”，填写设备名称、分组、位置以及需要维护的资产字段。',
      '创建设备后立即保存 Agent 密钥或复制安装命令；密钥关闭弹窗后不会再次显示。',
      'Agent 完成首次上报后，设备会从等待接入变为在线，并开始累积资源历史。',
    ],
    note: '轮换密钥会让旧密钥立即失效。执行前先准备好更新目标服务器配置并重启 Agent。',
    keywords: ['添加设备', '安装命令', '密钥', '节点', '服务器'],
  },
  {
    id: 'device-detail', category: '监控入门', title: '设备详情、资产与记录', icon: ListChecks, route: '/devices', entry: '设备管理 → 点击设备名称',
    access: '查看和操作均受该设备的权限范围限制',
    summary: '查看趋势、主机、磁盘、进程、容器、端口、安全巡检以及设备工作记录。',
    steps: [
      '在趋势与主机页先确认数据年龄、负载、吞吐和硬件健康，再切换到具体资源标签。',
      '在“资产与记录”补充资产归属，并记录变更、巡检和交接事项，运行总览会汇总近期记录。',
      '进程和容器页先选择历史对象查看趋势，再用快照表或移动端列表核对当前状态。',
    ],
    note: '设备显示离线不代表历史数据丢失。先读取红色诊断条中的最近上报时间和原因，再决定是否轮换密钥。',
    keywords: ['资产信息', '工作记录', '进程', '容器', '端口', '磁盘', '安全巡检'],
  },
  {
    id: 'discovery', category: '监控入门', title: '网络发现', icon: Radar, route: '/discovery', entry: '左侧导航 → 网络发现',
    access: '管理员或运维人员', roles: ['ADMIN', 'OPERATOR'],
    summary: '从总控服务器扫描私网网段和常见端口，发现尚未登记的主机。',
    steps: [
      '输入 /24 到 /32 的 RFC1918 私网 CIDR，并填写最多 32 个需要探测的端口。',
      '调整单端口超时与并发数后开始扫描，在右侧记录中查看运行进度和结果。',
      '对发现结果使用“使用地址添加设备”，系统会带着地址跳转到设备创建流程。',
    ],
    note: '扫描从总控服务器发起，只支持私网。结果为空时检查总控到目标网段的路由和防火墙。',
    keywords: ['CIDR', '端口扫描', '发现主机', '私网'],
  },
  {
    id: 'services', category: '告警响应', title: '服务监控', icon: Activity, route: '/services', entry: '左侧导航 → 服务监控',
    access: '查看：所有账号；配置：管理员或运维人员',
    summary: '探测 HTTP、Ping、TCP、FTP、数据库协议、SNMP 和外部心跳。',
    steps: [
      '点击“新建监控”，选择探测类型并填写目标、周期、超时和连续失败阈值。',
      'HTTP 可设置期望状态码与响应体条件；HTTPS 还可设置证书到期告警天数。',
      '保存后可立即探测、查看最近 31 天历史；外部心跳需立即复制一次性命令到 cron 或 CI。',
    ],
    note: '延迟阈值设为 0 表示不按延迟告警。先用较宽松阈值观察基线，再逐步收紧。',
    keywords: ['HTTP', 'Ping', 'TCP', '数据库', '心跳', '证书'],
  },
  {
    id: 'alert-rules', category: '告警响应', title: '告警规则', icon: SlidersHorizontal, route: '/alert-rules', entry: '左侧导航 → 告警规则',
    access: '全局规则由管理员管理；运维人员可管理有权限的设备规则',
    summary: '针对资源、离线、进程、服务、容器和自定义指标设置触发条件。',
    steps: [
      '点击“新建规则”，选择全局或指定设备范围，并选择要评估的指标。',
      '为进程、服务、容器或自定义指标填写目标名称，再设置阈值、级别和启用状态。',
      '保存后规则会在每次 Agent 上报时自动评估，命中时生成告警事件。',
    ],
    note: '先从少量高价值规则开始。阈值过紧会造成通知噪声，建议结合运行报告和趋势调整。',
    keywords: ['CPU', '内存', '离线', '阈值', '规则'],
  },
  {
    id: 'alerts', category: '告警响应', title: '告警事件', icon: BellRing, route: '/alerts', entry: '左侧导航或右上角铃铛 → 告警事件',
    access: '所有账号可查看；确认操作受设备告警权限限制',
    summary: '按状态、级别和设备筛选事件，并确认正在处理的告警。',
    steps: [
      '使用状态、级别和设备筛选器缩小范围，优先处理严重且仍为待处理的事件。',
      '点击单条“确认”，或勾选多条待处理事件后执行批量确认，留下处理人和时间。',
      '查看通知列判断是否已发送或被维护窗口静默；指标恢复后事件会自动标记为已恢复。',
    ],
    note: '“确认”表示有人接手，不等于故障已经恢复。最终恢复状态由后续采集或服务探测结果决定。',
    keywords: ['确认告警', '批量确认', '已恢复', '通知'],
  },
  {
    id: 'maintenance', category: '告警响应', title: '维护静默', icon: CalendarClock, route: '/maintenance', entry: '左侧导航 → 维护静默',
    access: '管理员可管理全局窗口；运维人员可管理有权限的设备窗口',
    summary: '在发布、迁移和检修期间保留事件，但暂停通知发送。',
    steps: [
      '点击“新建窗口”，填写名称、作用范围、开始与结束时间以及时区。',
      '按需要选择单次、每天或每周重复，并填写原因方便值班人员判断。',
      '保存并启用后，窗口内事件仍会记录；窗口结束仍未恢复的故障会补发通知。',
    ],
    note: '维护窗口不是关闭监控。时间范围和时区填错会直接影响通知，请在变更前复核。',
    keywords: ['静默', '发布', '检修', '通知抑制'],
  },
  {
    id: 'topology', category: '告警响应', title: '网络拓扑', icon: GitBranch, route: '/topology', entry: '左侧导航 → 网络拓扑',
    access: '所有账号',
    summary: '从服务探测目标推断总控、设备与外部服务之间的关系。',
    steps: [
      '先在服务监控中创建带有可解析目标地址的探测，拓扑会自动生成关系。',
      '点击关系图中的节点，右侧会显示地址、主机名、服务数量和相关探测。',
      '出现故障时从异常服务节点向上查看关联设备，快速判断影响范围。',
    ],
    note: '拓扑基于现有探测关系推断，不替代完整的网络发现或配置管理数据库。',
    keywords: ['关系图', '影响范围', '节点关系'],
  },
  {
    id: 'reports', category: '告警响应', title: '运行报告', icon: BarChart3, route: '/reports', entry: '左侧导航 → 运行报告',
    access: '所有账号，内容按数据权限显示',
    summary: '按统一时间窗口汇总节点资源、服务可用率和告警活动。',
    steps: [
      '选择报告时间范围，查看节点平均资源、峰值压力和采集点数量。',
      '检查服务可用率、平均延迟和异常次数，再结合告警摘要定位重复问题。',
      '需要交接或复盘时点击“导出 CSV”，保存当前时间窗口的数据。',
    ],
    note: '报告数据依赖历史采集。刚接入的设备或新建服务需要等待产生足够样本。',
    keywords: ['CSV', '可用率', '复盘', '峰值'],
  },
  {
    id: 'ddns', category: '自动化运维', title: '动态域名解析', icon: Globe2, route: '/ddns', entry: '左侧导航 → 动态域名解析',
    access: '查看：所有账号；配置：管理员或运维人员',
    summary: 'Agent 上报新地址后，通过 Webhook 模板更新关联域名记录。',
    steps: [
      '创建配置并填写域名、IPv4/IPv6 类型、Webhook 地址、请求方式和重试次数。',
      '按供应商要求配置请求头、请求体模板与凭据，敏感内容会在服务端加密保存。',
      '保存后先执行“测试更新”，再到设备编辑中把目标设备关联到该 DDNS 配置。',
    ],
    note: '更新配置时凭据留空会保留旧值。测试成功后再启用，避免错误模板批量更新记录。',
    keywords: ['Webhook', 'IPv4', 'IPv6', '域名'],
  },
  {
    id: 'tasks', category: '自动化运维', title: '任务执行', icon: Terminal, route: '/tasks', entry: '左侧导航 → 任务执行',
    access: '创建任务需管理员或运维人员及设备任务权限',
    summary: '向显式启用远程能力的 Agent 下发受控命令任务。',
    steps: [
      '确认目标 Agent 已显式开启命令执行能力，再点击“创建任务”选择可操作设备。',
      '填写命令、每行一个参数、超时和输出上限；参数不会经过 Shell 解析。',
      '创建后观察排队、运行、成功或失败状态，点击任务查看标准输出和标准错误。',
    ],
    note: '只对可信设备启用远程执行。不要把密钥、密码或其他敏感信息写进命令参数。',
    keywords: ['远程命令', '标准输出', '超时', 'Agent 能力'],
  },
  {
    id: 'tokens', category: '自动化运维', title: 'API Token', icon: KeyRound, route: '/tokens', entry: '左侧导航 → API Token',
    access: '所有登录账号可按自身权限创建',
    summary: '为移动端或自动化工具签发最小权限、可限设备和有效期的凭据。',
    steps: [
      '点击“创建 Token”，先选择只读 scope，再按用途补充必要的写入或任务权限。',
      '按需要限制服务器白名单并设置有效期，避免签发范围过大的长期凭据。',
      '创建后立即复制明文或完成二维码绑定；关闭窗口后明文无法恢复。',
    ],
    note: '二维码与 Token 明文拥有相同权限。发生泄露时立即吊销并重新签发。',
    keywords: ['scope', '鸿蒙', '二维码', '移动端', '吊销'],
  },
  {
    id: 'settings', category: '系统管理', title: '系统设置', icon: Settings, route: '/settings', entry: '左侧导航 → 系统设置',
    access: '仅管理员', roles: ['ADMIN'],
    summary: '管理站点与部署、监控策略、通知渠道、安全存储、Token 和系统更新。',
    steps: [
      '在左侧设置索引选择分区；修改后先检查右上角“有未保存修改”，再统一保存。',
      '配置邮件、钉钉、企业微信或通用 Webhook 后保存，再发送测试消息并查看投递记录。',
      '在监控策略中设置留存、离线阈值和上报周期；版本升级前先检查备份与更新状态。',
    ],
    note: '通知凭据需要部署端加密密钥才能保存。敏感字段读取时不会回显原文，留空通常表示保留。',
    keywords: ['通知渠道', '监控策略', '系统更新', '站点图标', 'Webhook'],
  },
  {
    id: 'push-kit', category: '系统管理', title: '华为 Push Kit（HarmonyOS NEXT）', icon: Smartphone, route: '/settings', entry: '系统设置 → 通知渠道 → 华为 Push Kit',
    access: '仅管理员', roles: ['ADMIN'],
    summary: '为 HarmonyOS NEXT / 5.x 及以上设备配置华为 Push Kit V3 服务账号，并从已登记设备发起测试推送。',
    steps: [
      '在华为 Push Kit 分区填写项目 ID、Key ID、子账号和 PKCS#8 RSA 私钥；私钥只会加密保存，不会在设置接口回显。',
      '保存后先校验服务账号。启用前必须具备完整账号和有效私钥，通知分类默认使用 MARKETING。',
      'HarmonyOS App 登记 Push Token 后，管理员可查看 Token 尾号、设备版本和登记时间，并按设备发送测试消息。',
    ],
    note: '这是华为 Push Kit V3 通道，只面向 HarmonyOS NEXT / 5.x+，与 Web Push、FCM、APNs、Webhook 及旧版华为 OAuth Push API 分开。',
    keywords: ['Push Kit', '华为', 'HarmonyOS NEXT', 'Push Token', 'V3', '测试推送'],
  },
  {
    id: 'backups', category: '系统管理', title: '备份与恢复', icon: Archive, route: '/backups', entry: '左侧导航 → 备份与恢复',
    access: '仅管理员', roles: ['ADMIN'],
    summary: '创建 PostgreSQL 恢复点，设置每日自动备份和保留数量。',
    steps: [
      '在重大设置修改或系统更新前点击“立即备份”，等待状态完成。',
      '启用每天 03:00 自动备份并设置保留数量，保存策略后定期检查恢复点列表。',
      '需要恢复时选择目标文件并确认；恢复是高风险操作，应先保留当前数据库副本。',
    ],
    note: '备份文件保存在总控项目目录。主机级故障防护还需要把备份目录同步到独立存储。',
    keywords: ['数据库', '恢复点', '自动备份', '保留策略'],
  },
  {
    id: 'users', category: '系统管理', title: '账号权限', icon: Users, route: '/users', entry: '左侧导航 → 账号权限',
    access: '仅管理员', roles: ['ADMIN'],
    summary: '创建管理员、运维和只读账号，并分配设备级查看、管理、告警和任务权限。',
    steps: [
      '点击“新建账号”，选择与职责匹配的角色，避免把日常账号都设置为管理员。',
      '对非管理员账号打开“设备权限”，分别配置查看、管理、告警和任务执行范围。',
      '人员职责变化时及时停用账号或收回设备权限，并在审计日志中复核变更。',
    ],
    note: '角色是全局边界，设备权限是资源边界。两层都满足时，相关操作按钮才会出现。',
    keywords: ['角色', '只读用户', '运维人员', '设备权限'],
  },
  {
    id: 'audit', category: '系统管理', title: '审计日志', icon: ClipboardList, route: '/audit', entry: '左侧导航 → 审计日志',
    access: '仅管理员', roles: ['ADMIN'],
    summary: '追踪设备、规则、账号和系统设置的关键变更。',
    steps: [
      '按时间查看关键管理操作，核对操作者、动作对象和结果。',
      '在故障复盘或权限调查时，把审计记录与告警、任务和设备工作记录交叉比对。',
      '发现非预期变更后先限制相关账号权限，再恢复正确配置并记录处理过程。',
    ],
    note: '审计日志用于追溯，不代替备份。配置被误改时仍需要可靠恢复点。',
    keywords: ['操作记录', '追溯', '变更'],
  },
  {
    id: 'profile', category: '系统管理', title: '个人资料、密码与 2FA', icon: ShieldCheck, entry: '右上角账号菜单 → 个人资料与密码',
    access: '所有登录账号',
    summary: '修改显示名称和密码，并为当前账号启用身份验证器双因素认证。',
    steps: [
      '打开右上角账号菜单，进入“个人资料与密码”，修改显示名称时直接保存即可。',
      '修改密码需要同时填写当前密码和至少 12 位的新密码。',
      '启用 2FA 时输入当前密码生成二维码，用身份验证器扫描后填写 6 位验证码完成绑定。',
    ],
    note: '启用 2FA 前确认身份验证器时间准确，并妥善保管绑定信息，避免账号无法登录。',
    keywords: ['双因素认证', '密码', '身份验证器', '2FA'],
  },
]

const currentRoleName = computed(() => roleNames[auth.user?.role ?? 'VIEWER'])

function canOpen(topic: GuideTopic) {
  return !topic.roles || topic.roles.includes(auth.user?.role ?? 'VIEWER')
}

function canOpenQuickStart(step: QuickStartStep) {
  return step.roles.includes(auth.user?.role ?? 'VIEWER')
}

const filteredTopics = computed(() => {
  const normalizedKeyword = keyword.value.trim().toLowerCase()
  return topics.filter((topic) => {
    if (category.value !== '全部' && topic.category !== category.value) return false
    if (!normalizedKeyword) return true
    const searchable = [topic.title, topic.summary, topic.entry, topic.access, topic.note, ...topic.steps, ...(topic.keywords ?? [])].join(' ').toLowerCase()
    return searchable.includes(normalizedKeyword)
  })
})

function clearFilters() {
  keyword.value = ''
  category.value = '全部'
}
</script>

<template>
  <section class="guide-page">
    <PageHeader eyebrow="PRODUCT GUIDE" title="功能使用指南" description="从设备接入到告警响应，按真实控制台流程查找操作步骤与权限要求。">
      <template #actions><span class="guide-current-role"><ShieldCheck :size="15" />当前身份：{{ currentRoleName }}</span></template>
    </PageHeader>

    <section class="guide-quick-start" aria-labelledby="guide-quick-start-title">
      <header><span><Rocket :size="19" /></span><div><h2 id="guide-quick-start-title">首次使用建议顺序</h2><p>先打通数据链路，再补齐告警、通知和恢复能力。</p></div></header>
      <ol>
        <li v-for="(step, index) in quickStart" :key="step.title">
          <span>{{ String(index + 1).padStart(2, '0') }}</span>
          <div><strong>{{ step.title }}</strong><p>{{ step.description }}</p></div>
          <RouterLink v-if="canOpenQuickStart(step)" :to="step.route" :aria-label="`前往${step.title}`" :title="`前往${step.title}`"><ArrowRight :size="16" /></RouterLink>
          <span v-else class="guide-quick-locked" title="当前角色无操作权限"><LockKeyhole :size="15" /><small>无权限</small></span>
        </li>
      </ol>
    </section>

    <section class="guide-controls" aria-label="指南筛选">
      <label class="guide-search-field"><span>搜索功能或操作</span><el-input v-model="keyword" clearable placeholder="例如：Agent、容器、通知、备份"><template #prefix><Search :size="16" /></template></el-input></label>
      <div class="guide-category-field"><span>按模块筛选</span><div class="guide-category-scroll"><el-segmented v-model="category" :options="categoryOptions" aria-label="指南功能分类" /></div></div>
    </section>

    <div class="guide-layout">
      <aside class="guide-index" aria-labelledby="guide-index-title">
        <header><BookOpen :size="17" /><div><strong id="guide-index-title">本页目录</strong><small>{{ filteredTopics.length }} / {{ topics.length }} 项功能</small></div></header>
        <nav aria-label="可见指南条目">
          <a v-for="topic in filteredTopics" :key="topic.id" :href="`#guide-${topic.id}`"><component :is="topic.icon" :size="15" /><span>{{ topic.title }}</span></a>
        </nav>
        <div class="guide-index-note"><LockKeyhole :size="15" /><p>指南展示全部功能；受限页面会根据当前角色锁定入口。</p></div>
      </aside>

      <div class="guide-content">
        <div class="guide-results-head"><div><h2>{{ category === '全部' ? '全部功能' : category }}</h2><p>{{ keyword ? `正在搜索“${keyword}”` : '按实际工作流整理的控制台操作说明' }}</p></div><span>{{ filteredTopics.length }} 项结果</span></div>

        <div v-if="filteredTopics.length" class="guide-topic-list">
          <article v-for="topic in filteredTopics" :id="`guide-${topic.id}`" :key="topic.id" class="guide-topic">
            <header class="guide-topic-head">
              <span class="guide-topic-icon"><component :is="topic.icon" :size="19" /></span>
              <div><span>{{ topic.category }}</span><h2>{{ topic.title }}</h2><p>{{ topic.summary }}</p></div>
              <span class="guide-access-badge" :data-locked="!canOpen(topic)">{{ canOpen(topic) ? topic.access : '当前账号不可访问' }}</span>
            </header>
            <div class="guide-topic-body">
              <section><h3>操作步骤</h3><ol><li v-for="step in topic.steps" :key="step">{{ step }}</li></ol></section>
              <aside class="guide-topic-tip"><Lightbulb :size="17" /><div><strong>使用提醒</strong><p>{{ topic.note }}</p></div></aside>
            </div>
            <footer>
              <span><MousePointerClick :size="15" />{{ topic.entry }}</span>
              <RouterLink v-if="topic.route && canOpen(topic)" :to="topic.route">进入功能<ArrowRight :size="15" /></RouterLink>
              <span v-else-if="topic.route" class="guide-locked-entry"><LockKeyhole :size="14" />当前角色无页面权限</span>
              <span v-else class="guide-inline-entry">从账号菜单打开</span>
            </footer>
          </article>
        </div>
        <div v-else class="panel guide-empty"><EmptyState title="没有找到相关指南" description="尝试缩短关键词，或清空分类后重新查找。"><el-button @click="clearFilters">清空筛选</el-button></EmptyState></div>
      </div>
    </div>
  </section>
</template>
