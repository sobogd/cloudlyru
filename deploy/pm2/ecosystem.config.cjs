// pm2 ecosystem: pm2 start deploy/pm2/ecosystem.config.cjs
// env берётся из /opt/cloudlyru/.env (main.ts подключает dotenv/config из cwd)
module.exports = {
  apps: [
    {
      name: 'cloudlyru',
      script: 'dist/main.js',
      cwd: '/opt/cloudlyru',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      max_memory_restart: '600M',
      env: {
        NODE_ENV: 'production',
      },
      out_file: '/var/log/cloudlyru.out.log',
      error_file: '/var/log/cloudlyru.err.log',
      merge_logs: true,
      time: true,
    },
  ],
};
