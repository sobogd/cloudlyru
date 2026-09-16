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
      // Потолок памяти процесса API. На него ориентируются лимиты распаковки архивов
      // (UNZIP_BUFFER_LIMIT_MB, дефолт 64 МБ: файл читается в память одним проходом, то есть
      // в пике живут буфер и Buffer.concat) — поднимать 600M имеет смысл только вместе с ними.
      // CONVERT_MEM_MB к этому потолку отношения не имеет: это RLIMIT_AS отдельного процесса
      // конвертера, а не память API.
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
