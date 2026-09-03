import { defineConfig } from 'vitepress'

export default defineConfig({
  lang: 'zh-CN',
  title: '星辰监控',
  titleTemplate: '星辰监控 | :title',
  description: '开源、自托管的多服务器实时监控与统一运维平台',
  cleanUrls: true,
  lastUpdated: true,
  appearance: 'dark',
  head: [
    ['meta', { name: 'theme-color', content: '#070a0d' }],
    ['meta', { name: 'color-scheme', content: 'dark' }],
    ['link', { rel: 'icon', type: 'image/png', href: '/brand-icon.png' }],
    ['link', { rel: 'apple-touch-icon', href: '/brand-icon.png' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: '星辰监控' }],
    ['meta', { property: 'og:description', content: '开源、自托管的多服务器实时监控与统一运维平台' }],
    ['meta', { property: 'og:image', content: '/brand-icon.png' }],
  ],
  themeConfig: {
    logo: '/brand-icon.png',
    siteTitle: '星辰监控',
    nav: [
      { text: '首页', link: '/' },
      { text: '快速安装', link: '/quick-start' },
      { text: '使用指南', link: '/user-guide' },
      { text: 'API', link: '/api' },
      {
        text: '源码',
        items: [
          { text: 'GitHub', link: 'https://github.com/Pstarchen/monitor-for-server' },
          { text: 'Gitee', link: 'https://gitee.com/starchen520/monitor-for-server' },
        ],
      },
    ],
    sidebar: [
      {
        text: '开始使用',
        items: [
          { text: '5 分钟快速安装', link: '/quick-start' },
          { text: '完整新手指南', link: '/user-guide' },
          { text: '总控服务器', link: '/controller-server' },
          { text: '受监控服务器', link: '/monitored-agent' },
        ],
      },
      {
        text: '部署与维护',
        items: [
          { text: '部署与运维', link: '/deployment' },
          { text: '系统架构', link: '/architecture' },
          { text: '备份与生产检查', link: '/production-audit' },
          { text: '常见问题', link: '/faq' },
        ],
      },
      {
        text: '集成与开发',
        items: [
          { text: 'HTTP 与 WebSocket API', link: '/api' },
          { text: 'HarmonyOS Push Kit', link: '/huawei-push-kit' },
        ],
      },
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/Pstarchen/monitor-for-server' },
    ],
    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' },
          modal: {
            noResultsText: '没有找到相关内容',
            resetButtonTitle: '清除查询',
            footer: { selectText: '选择', navigateText: '切换', closeText: '关闭' },
          },
        },
      },
    },
    outline: { level: [2, 3], label: '本页内容' },
    returnToTopLabel: '返回顶部',
    sidebarMenuLabel: '文档目录',
    darkModeSwitchLabel: '外观',
    lastUpdatedText: '最后更新',
    docFooter: { prev: '上一篇', next: '下一篇' },
    editLink: {
      pattern: 'https://github.com/Pstarchen/monitor-for-server/edit/main/docs/:path',
      text: '在 GitHub 上编辑此页',
    },
    footer: {
      message: '开源、自托管，数据留在你自己的基础设施中。',
      copyright: 'Copyright © 2026 星辰监控贡献者',
    },
  },
})
