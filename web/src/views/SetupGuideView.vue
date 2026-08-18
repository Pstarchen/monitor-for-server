<script setup lang="ts">
import { computed, ref } from 'vue'
import { Activity, ArrowRight, CheckCircle2, Clipboard, ExternalLink, FileKey2, LockKeyhole, ServerCog, Terminal } from 'lucide-vue-next'

type Platform = 'linux' | 'windows'

const platform = ref<Platform>('linux')
const copied = ref('')

const cloneCommand = 'git clone https://github.com/Pstarchen/monitor-for-server.git'
const installCommand = computed(() => platform.value === 'linux'
  ? 'bash ./deploy/install-controller.sh'
  : 'powershell -ExecutionPolicy Bypass -File .\\deploy\\install-controller.ps1')
const temporaryHttpCommand = computed(() => platform.value === 'linux'
  ? 'bash ./deploy/install-controller.sh --allow-insecure-http'
  : 'powershell -ExecutionPolicy Bypass -File .\\deploy\\install-controller.ps1 -AllowInsecureHttp')
const updateCommand = computed(() => platform.value === 'linux'
  ? 'git pull && docker compose up --build -d'
  : 'git pull; docker compose up --build -d')

const steps = [
  { number: '01', title: '准备总终端主机', description: '准备 Docker Engine 24+、Compose v2 和外部 MySQL 数据库账号；同机数据库使用 host.docker.internal。', icon: ServerCog },
  { number: '02', title: '运行交互式安装器', description: '安装器会询问数据库连接、入口、站点、时区和管理员信息，并生成私有加密密钥。', icon: Terminal },
  { number: '03', title: '完成首登检查', description: '打开入口登录，确认健康状态，再在设备管理中创建第一台受监控服务器。', icon: CheckCircle2 },
]

async function copy(value: string, key: string) {
  try {
    await navigator.clipboard.writeText(value)
    copied.value = key
    window.setTimeout(() => { if (copied.value === key) copied.value = '' }, 1600)
  } catch {
    copied.value = ''
  }
}
</script>

<template>
  <main class="setup-page">
    <header class="auth-topbar setup-topbar">
      <RouterLink class="brand auth-brand" to="/login">
        <span class="brand-mark"><Activity :size="19" /></span>
        <span><strong>观澜监控</strong><small>PRIVATE OPS</small></span>
      </RouterLink>
      <div class="setup-topbar-actions">
        <span class="setup-topbar-label">总终端安装指引</span>
        <RouterLink class="setup-login-link" to="/login">返回登录 <ArrowRight :size="15" /></RouterLink>
      </div>
    </header>

    <div class="setup-layout">
      <aside class="setup-intro">
        <span class="setup-intro-icon"><FileKey2 :size="22" /></span>
        <p class="eyebrow">CONTROLLER INSTALLATION</p>
        <h1>把首次部署<br>变成一条清晰路径</h1>
        <p class="setup-intro-copy">不依赖隐藏的环境默认值。安装器会在本机询问必要信息，生成私有配置并校验 Compose，然后启动总终端服务。</p>
        <div class="setup-security-note"><LockKeyhole :size="15" /><span>密码和密钥只写入总终端主机的 `.env`，不会发送到本页面。</span></div>
      </aside>

      <section class="setup-workspace" aria-label="安装步骤">
        <div class="setup-step-list">
          <article v-for="step in steps" :key="step.number" class="setup-step">
            <span class="setup-step-number">{{ step.number }}</span>
            <span class="setup-step-icon"><component :is="step.icon" :size="17" /></span>
            <div><h2>{{ step.title }}</h2><p>{{ step.description }}</p></div>
          </article>
        </div>

        <div class="setup-command-section">
          <div class="setup-section-heading"><div><p class="eyebrow">START HERE</p><h2>复制安装命令</h2></div><span class="setup-local-badge">交互式配置</span></div>
          <div class="setup-segmented" role="group" aria-label="选择总终端主机系统">
            <button type="button" :aria-pressed="platform === 'linux'" :class="{ active: platform === 'linux' }" @click="platform = 'linux'">Linux</button>
            <button type="button" :aria-pressed="platform === 'windows'" :class="{ active: platform === 'windows' }" @click="platform = 'windows'">Windows</button>
          </div>

          <div class="setup-command-block">
            <div class="setup-command-row"><code>{{ cloneCommand }}</code><button type="button" title="复制仓库命令" aria-label="复制仓库命令" @click="copy(cloneCommand, 'clone')"><Clipboard :size="16" /><span>{{ copied === 'clone' ? '已复制' : '复制' }}</span></button></div>
            <div class="setup-command-row"><code>{{ installCommand }}</code><button type="button" title="复制安装命令" aria-label="复制安装命令" @click="copy(installCommand, 'install')"><Clipboard :size="16" /><span>{{ copied === 'install' ? '已复制' : '复制' }}</span></button></div>
          </div>
          <p class="setup-command-hint">安装器会拒绝覆盖现有 `.env`。需要重做配置时先备份，再显式使用 `--overwrite` 或 `-Overwrite`。</p>
          <p class="setup-insecure-note"><LockKeyhole :size="15" /><span>暂时没有域名时，只有在确认风险后才使用临时 IP/HTTP 命令。登录密码会经过明文网络；宝塔反代和 HTTPS 生效后必须切换回安全配置。</span></p>
          <div class="setup-command-row"><code>{{ temporaryHttpCommand }}</code><button type="button" title="复制临时 HTTP 安装命令" aria-label="复制临时 HTTP 安装命令" @click="copy(temporaryHttpCommand, 'temporary')"><Clipboard :size="16" /><span>{{ copied === 'temporary' ? '已复制' : '临时 HTTP' }}</span></button></div>
        </div>

        <div class="setup-checklist">
          <div class="setup-section-heading"><div><p class="eyebrow">AFTER INSTALL</p><h2>启动后检查</h2></div><ExternalLink :size="17" /></div>
          <ul>
            <li><CheckCircle2 :size="16" /><span>访问安装器最后提示的 HTTPS 地址，使用刚设置的管理员账号登录。</span></li>
            <li><CheckCircle2 :size="16" /><span>在系统设置确认站点入口、时区和默认采集周期，不再依赖 localhost 默认值。</span></li>
            <li><CheckCircle2 :size="16" /><span>在设备管理创建节点，复制一次性 Agent 安装命令到受监控服务器。</span></li>
          </ul>
          <div class="setup-update-row"><span><Terminal :size="15" />升级总终端</span><code>{{ updateCommand }}</code><button type="button" title="复制升级命令" aria-label="复制升级命令" @click="copy(updateCommand, 'update')"><Clipboard :size="15" /></button></div>
        </div>
      </section>
    </div>
  </main>
</template>
