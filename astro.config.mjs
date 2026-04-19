import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://opencolin.github.io',
  base: '/kubeclaw',
  integrations: [
    starlight({
      title: 'KubeClaw',
      description: 'Deploy OpenClaw and NemoClaw on Nebius Managed Kubernetes',
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/opencolin/kubeclaw' },
      ],
      editLink: {
        baseUrl: 'https://github.com/opencolin/kubeclaw/edit/main/',
      },
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'Quick Start', slug: 'quick-start' },
            { label: 'Prerequisites', slug: 'prerequisites' },
            { label: 'Deployment Guide', slug: 'deployment-guide' },
          ],
        },
        {
          label: 'Configuration',
          items: [
            { label: 'GPU Configuration', slug: 'gpu-configuration' },
            { label: 'Monitoring Setup', slug: 'monitoring-setup' },
            { label: 'Security Hardening', slug: 'security-hardening' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Architecture', slug: 'architecture' },
            { label: 'Troubleshooting', slug: 'troubleshooting' },
            { label: 'FAQ', slug: 'faq' },
          ],
        },
      ],
    }),
  ],
});
