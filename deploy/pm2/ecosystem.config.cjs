// pm2 ecosystem (ручной запуск): pm2 start deploy/pm2/ecosystem.config.cjs
// Пути соответствуют реальному размещению на проде и сервисному пользователю deployer
// (тот же каталог, что использует автодеплой из .github/workflows/deploy.yml):
//   /home/deploy/apps/cloudlyru  — код и .env (main.ts читает dotenv из cwd)
//   логи — рядом с приложением, чтобы deployer мог их читать без root
module.exports = {
  apps: [
    {
      name: 'cloudlyru',
      script: 'dist/main.js',
      cwd: '/home/deploy/apps/cloudlyru',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      max_memory_restart: '600M',
      env: {
        NODE_ENV: 'production',
      },
      out_file: '/home/deploy/apps/cloudlyru/logs/out.log',
      error_file: '/home/deploy/apps/cloudlyru/logs/err.log',
      merge_logs: true,
      time: true,
    },
  ],
};
