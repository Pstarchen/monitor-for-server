<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import {
  Activity,
  ArrowRight,
  BellRing,
  Check,
  CircleGauge,
  CloudCog,
  Code2,
  Copy,
  DatabaseBackup,
  ExternalLink,
  FileKey2,
  GitBranch,
  Github,
  KeyRound,
  Network,
  Radar,
  Server,
  ShieldCheck,
  Terminal,
  Waypoints,
} from 'lucide-vue-next'
import HeroScene from './HeroScene.vue'

type InstallMode = 'linux' | 'windows'
type CopyState = 'idle' | 'copied' | 'error'

const installMode = ref<InstallMode>('linux')
const copyState = ref<CopyState>('idle')
const pageRoot = ref<HTMLElement>()
const scrollProgress = ref(0)
let revealObserver: IntersectionObserver | undefined
let scrollFrame = 0

const commands: Record<InstallMode, string> = {
  linux: `git clone https://github.com/Pstarchen/monitor-for-server.git xingchen-monitor
cd xingchen-monitor
sudo bash ./deploy/install-controller.sh`,
  windows: `git clone https://github.com/Pstarchen/monitor-for-server.git xingchen-monitor
Set-Location xingchen-monitor
powershell -ExecutionPolicy Bypass -File .\\deploy\\install-controller.ps1`,
}

const currentCommand = computed(() => commands[installMode.value])

const heroFacts = [
  { value: 'Linux + Windows', label: '跨平台节点接入' },
  { value: '7 类探测', label: '服务可用性监测' },
  { value: 'Self-hosted', label: '数据留在本地' },
]

const features = [
  {
    icon: CircleGauge,
    number: '01',
    title: '实时主机视图',
    copy: '集中查看 CPU、内存、磁盘、网络、进程、端口与硬件健康，WebSocket 持续推送最新状态。',
    detail: 'Linux / Windows / Docker',
  },
  {
    icon: BellRing,
    number: '02',
    title: '完整告警闭环',
    copy: '资源阈值、离线、服务探测和外部心跳进入同一事件流，支持确认、恢复与维护静默。',
    detail: '邮件 / 钉钉 / 企业微信 / Webhook',
  },
  {
    icon: Radar,
    number: '03',
    title: '服务与网络探测',
    copy: '覆盖 HTTP、Ping、TCP、Redis、PostgreSQL、MySQL 与证书到期，快速定位业务异常。',
    detail: '主动探测 / 可用率历史 / 私网发现',
  },
  {
    icon: ShieldCheck,
    number: '04',
    title: '权限与安全边界',
    copy: '角色、设备级权限、TOTP、审计、加密配置和 scoped API Token 共同收紧运维边界。',
    detail: '远程能力默认关闭',
  },
]

const signalItems = [
  { icon: Activity, title: '指标实时推送', copy: '秒级观察节点状态' },
  { icon: Network, title: '多节点统一管理', copy: '跨云与本地主机接入' },
  { icon: ShieldCheck, title: '完全私有部署', copy: '基础数据自主掌控' },
]

const boundaries = [
  { icon: KeyRound, number: '01', title: '一次性设备密钥', copy: '明文仅在创建或轮换时显示，遗失后重新签发。' },
  { icon: FileKey2, number: '02', title: '远程能力默认关闭', copy: '命令执行与文件操作需要在每台 Agent 上显式启用。' },
  { icon: DatabaseBackup, number: '03', title: '变更全程可追踪', copy: '恢复点、版本检查、更新任务与敏感操作都有明确记录。' },
]

const docsLinks = [
  { icon: Terminal, title: '快速安装', copy: '从空服务器到首次登录', href: '/quick-start' },
  { icon: Activity, title: '完整使用指南', copy: '设备、告警、服务与日常值班', href: '/user-guide' },
  { icon: Server, title: 'Agent 接入', copy: 'Linux、Windows 与采集范围', href: '/monitored-agent' },
  { icon: DatabaseBackup, title: '备份与更新', copy: '恢复点、升级与生产检查', href: '/deployment' },
  { icon: GitBranch, title: '系统架构', copy: '组件职责、数据流和安全边界', href: '/architecture' },
  { icon: Code2, title: 'API 与集成', copy: 'REST、WebSocket、Token 与 MCP', href: '/api' },
]

function updateScrollProgress() {
  scrollFrame = 0
  const root = document.documentElement
  const scrollable = root.scrollHeight - root.clientHeight
  scrollProgress.value = scrollable > 0 ? Math.min(root.scrollTop / scrollable, 1) : 0
}

function handleScroll() {
  if (!scrollFrame) scrollFrame = window.requestAnimationFrame(updateScrollProgress)
}

onMounted(() => {
  const root = pageRoot.value
  if (!root) return

  const revealItems = root.querySelectorAll<HTMLElement>('.reveal-item')
  if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    root.classList.add('motion-ready')
    revealObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return
        entry.target.classList.add('is-visible')
        revealObserver?.unobserve(entry.target)
      })
    }, { threshold: 0.14, rootMargin: '0px 0px -8% 0px' })
    revealItems.forEach((item) => revealObserver?.observe(item))
  }

  updateScrollProgress()
  window.addEventListener('scroll', handleScroll, { passive: true })
  window.addEventListener('resize', handleScroll, { passive: true })
})

onBeforeUnmount(() => {
  revealObserver?.disconnect()
  window.cancelAnimationFrame(scrollFrame)
  window.removeEventListener('scroll', handleScroll)
  window.removeEventListener('resize', handleScroll)
})

async function copyCommand() {
  try {
    await navigator.clipboard.writeText(currentCommand.value)
    copyState.value = 'copied'
  } catch {
    copyState.value = 'error'
  }
  window.setTimeout(() => { copyState.value = 'idle' }, 1800)
}
</script>

<template>
  <main ref="pageRoot" class="mfs-home">
    <div class="page-progress" :style="{ transform: `scaleX(${scrollProgress})` }" aria-hidden="true" />
    <section class="mfs-hero" aria-labelledby="hero-title">
      <ClientOnly>
        <HeroScene />
      </ClientOnly>
      <div class="hero-scrim" aria-hidden="true" />
      <div class="home-shell hero-content">
        <div class="hero-copy">
          <div class="hero-kicker"><span aria-hidden="true" /> 开源 · 自托管 · 多节点</div>
          <h1 id="hero-title">星辰监控</h1>
          <p class="hero-tagline">让每一台服务器，都在清晰可控的轨道上。</p>
          <p class="hero-description">面向个人开发者与小型团队的开源监控平台。一个总控连接所有 Linux 与 Windows 主机，实时掌握运行状态、服务可用性与告警事件。</p>
          <div class="hero-actions">
            <a class="home-button home-button-primary" href="/quick-start">
              开始部署
              <ArrowRight :size="18" :stroke-width="1.8" aria-hidden="true" />
            </a>
            <a class="home-button home-button-secondary" href="https://github.com/Pstarchen/monitor-for-server" target="_blank" rel="noreferrer">
              <Github :size="18" :stroke-width="1.7" aria-hidden="true" />
              查看源码
            </a>
          </div>
          <div class="hero-facts" aria-label="平台能力概览">
            <div v-for="fact in heroFacts" :key="fact.value">
              <strong>{{ fact.value }}</strong>
              <span>{{ fact.label }}</span>
            </div>
          </div>
        </div>
      </div>
      <div class="hero-coordinate" aria-hidden="true">XC / OBSERVABILITY / 2026</div>
    </section>

    <section class="signal-strip" aria-label="星辰监控核心特性">
      <div class="home-shell signal-grid">
        <article v-for="item in signalItems" :key="item.title" class="reveal-item">
          <component :is="item.icon" :size="21" :stroke-width="1.55" aria-hidden="true" />
          <div><strong>{{ item.title }}</strong><span>{{ item.copy }}</span></div>
        </article>
      </div>
    </section>

    <section class="home-section capability-section" aria-labelledby="capability-title">
      <div class="home-shell">
        <div class="section-heading section-heading-dark reveal-item">
          <span class="section-index">01 / 能力</span>
          <div>
            <h2 id="capability-title">一个视角，读懂整片基础设施</h2>
            <p>采集、探测、告警与授权操作共享同一套设备和权限模型，让分散节点形成清晰的运行全景。</p>
          </div>
        </div>
        <div class="feature-ledger">
          <article v-for="feature in features" :key="feature.title" class="feature-row reveal-item">
            <span class="feature-number">{{ feature.number }}</span>
            <component :is="feature.icon" :size="25" :stroke-width="1.45" aria-hidden="true" />
            <h3>{{ feature.title }}</h3>
            <p>{{ feature.copy }}</p>
            <span class="feature-detail">{{ feature.detail }}</span>
          </article>
        </div>
      </div>
    </section>

    <section class="home-section architecture-section" aria-labelledby="architecture-title">
      <div class="home-shell architecture-layout">
        <div class="section-heading section-heading-light architecture-copy reveal-item" data-reveal="left">
          <span class="section-index">02 / 架构</span>
          <div>
            <h2 id="architecture-title">数据主动上报，公网入口保持收敛</h2>
            <p>Agent 主动连接总控。PostgreSQL 与 Redis 留在 Compose 内网，公网只开放带 TLS 的 Web 入口。</p>
            <a class="text-link" href="/architecture">查看安全边界 <ArrowRight :size="17" :stroke-width="1.7" aria-hidden="true" /></a>
          </div>
        </div>
        <div class="data-path reveal-item" data-reveal="right" aria-label="Agent 到总控再到浏览器的连接路径">
          <div class="data-path-head"><span>DATA PIPELINE</span><span class="path-live"><i /> ACTIVE</span></div>
          <span class="data-tracer" aria-hidden="true" />
          <div class="data-node">
            <Server :size="27" :stroke-width="1.45" aria-hidden="true" />
            <div><strong>Agent</strong><span>主动采集与断线缓冲</span></div>
            <small>OUTBOUND</small>
          </div>
          <Waypoints class="data-path-arrow" :size="23" :stroke-width="1.35" aria-hidden="true" />
          <div class="data-node data-node-controller">
            <CloudCog :size="29" :stroke-width="1.45" aria-hidden="true" />
            <div><strong>Controller</strong><span>鉴权、存储与告警计算</span></div>
            <small>PRIVATE</small>
          </div>
          <Waypoints class="data-path-arrow" :size="23" :stroke-width="1.35" aria-hidden="true" />
          <div class="data-node">
            <CircleGauge :size="27" :stroke-width="1.45" aria-hidden="true" />
            <div><strong>Web</strong><span>实时视图与授权操作</span></div>
            <small>TLS</small>
          </div>
        </div>
      </div>
    </section>

    <section class="home-section install-section" aria-labelledby="install-title">
      <div class="home-shell install-layout">
        <div class="install-console reveal-item" data-reveal="left">
          <div class="install-console-bar">
            <div class="console-title"><Terminal :size="16" aria-hidden="true" /><span>部署星辰监控</span></div>
            <div class="install-tabs" role="tablist" aria-label="总控安装平台">
              <button
                v-for="mode in (['linux', 'windows'] as InstallMode[])"
                :key="mode"
                type="button"
                role="tab"
                :aria-selected="installMode === mode"
                :class="{ active: installMode === mode }"
                @click="installMode = mode; copyState = 'idle'"
              >{{ mode === 'linux' ? 'Linux' : 'Windows' }}</button>
            </div>
            <button
              class="copy-button"
              :class="{ 'is-success': copyState === 'copied', 'is-error': copyState === 'error' }"
              type="button"
              :aria-label="copyState === 'copied' ? '安装命令已复制' : '复制安装命令'"
              @click="copyCommand"
            >
              <Check v-if="copyState === 'copied'" :size="17" :stroke-width="1.8" aria-hidden="true" />
              <Copy v-else :size="17" :stroke-width="1.7" aria-hidden="true" />
              <span>{{ copyState === 'copied' ? '已复制' : copyState === 'error' ? '复制失败' : '复制' }}</span>
            </button>
          </div>
          <pre role="tabpanel"><code>{{ currentCommand }}</code></pre>
          <div class="console-status"><span><i /> INSTALLER READY</span><span>PORT 18080</span></div>
          <p class="sr-only" aria-live="polite">{{ copyState === 'copied' ? '安装命令已复制到剪贴板' : copyState === 'error' ? '复制失败，请手动选择命令' : '' }}</p>
        </div>
        <div class="install-copy reveal-item" data-reveal="right">
          <span class="section-index">03 / 部署</span>
          <h2 id="install-title">一条清晰路径，完成首次上线</h2>
          <p>安装器会准备 PostgreSQL、Redis、服务端与 Web，随后引导你完成站点和首个管理员配置。</p>
          <ol class="install-steps">
            <li><span>01</span><div><strong>运行安装器</strong><small>准备容器与服务</small></div></li>
            <li><span>02</span><div><strong>完成初始化</strong><small>配置域名与管理员</small></div></li>
            <li><span>03</span><div><strong>接入节点</strong><small>上线后启用告警</small></div></li>
          </ol>
          <a class="text-link text-link-dark" href="/quick-start">阅读完整安装步骤 <ArrowRight :size="17" :stroke-width="1.7" aria-hidden="true" /></a>
        </div>
      </div>
    </section>

    <section class="home-section boundary-section" aria-labelledby="boundary-title">
      <div class="home-shell boundary-layout">
        <div class="section-heading section-heading-light boundary-copy reveal-item" data-reveal="left">
          <span class="section-index">04 / 安全</span>
          <div><h2 id="boundary-title">重要能力，默认就有边界</h2><p>先让监控稳定运行，再按职责逐项开放自动化与集成。</p></div>
        </div>
        <div class="boundary-list">
          <article v-for="item in boundaries" :key="item.title" class="reveal-item">
            <span>{{ item.number }}</span>
            <component :is="item.icon" :size="24" :stroke-width="1.5" aria-hidden="true" />
            <div><h3>{{ item.title }}</h3><p>{{ item.copy }}</p></div>
          </article>
        </div>
      </div>
    </section>

    <section class="home-section docs-section" aria-labelledby="docs-title">
      <div class="home-shell docs-layout">
        <div class="section-heading section-heading-dark docs-copy reveal-item" data-reveal="left">
          <span class="section-index">05 / WIKI</span>
          <div><h2 id="docs-title">从问题出发，快速找到答案</h2><p>安装、接入、排障和开发资料都在同一处，可全文搜索。</p></div>
        </div>
        <nav class="docs-grid" aria-label="Wiki 入口">
          <a v-for="(item, index) in docsLinks" :key="item.href" :href="item.href" class="docs-link reveal-item">
            <span>{{ String(index + 1).padStart(2, '0') }}</span>
            <component :is="item.icon" :size="21" :stroke-width="1.55" aria-hidden="true" />
            <div><strong>{{ item.title }}</strong><small>{{ item.copy }}</small></div>
            <ArrowRight :size="18" :stroke-width="1.6" aria-hidden="true" />
          </a>
        </nav>
      </div>
    </section>

    <section class="final-section" aria-labelledby="final-title">
      <div class="home-shell final-layout">
        <div class="reveal-item" data-reveal="left"><span>XINGCHEN MONITOR</span><h2 id="final-title">让基础设施始终在视野中</h2><p>开源、自托管，从第一台服务器开始。</p></div>
        <div class="final-actions reveal-item" data-reveal="right">
          <a class="home-button home-button-dark" href="/quick-start">开始部署 <ArrowRight :size="18" :stroke-width="1.7" aria-hidden="true" /></a>
          <a class="home-button home-button-ghost" href="https://monitor.xciy.cn" target="_blank" rel="noreferrer">查看在线状态 <ExternalLink :size="17" :stroke-width="1.7" aria-hidden="true" /></a>
        </div>
      </div>
    </section>
  </main>
</template>
