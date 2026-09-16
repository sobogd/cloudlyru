import { Module } from '@nestjs/common';
import { InvoicesModule } from './invoices/invoices.module';
import { ContactsModule } from './contacts/contacts.module';
import { ExpensesModule } from './expenses/expenses.module';
import { DeclarationsModule } from './declarations/declarations.module';
import { FiledDeclarationsModule } from './filed-declarations/filed-declarations.module';
import { BankAccountsModule } from './bank-accounts/bank-accounts.module';
import { TaxModule } from './tax/tax.module';
import { CompaniesModule } from './companies/companies.module';

/**
 * Раздел «Фактуры»: выставление инвойсов испанским autónomo, расходы, квартальные декларации
 * и отправка записей в AEAT (VeriFactu). Перенесён из отдельного сервиса iq-factura, который
 * жил на этом же сервере со своей базой; теперь это часть облака.
 *
 * Что изменилось при переносе (и почему здесь нет привычных по фактуре модулей):
 *  - `auth` — не нужен: пользователя аутентифицирует глобальный `AuthGuard` облака, а компания
 *    берётся из конфига (`FACTURA_COMPANY_ID`) в `FacturaContextGuard` (см. `factura-context.ts`);
 *  - `mail` — в фактуре он существовал ровно для кодов входа (OTP), а вход теперь общий с облаком;
 *  - `geo` — определял страну и валюту по IP для лендинга, лендинга больше нет;
 *  - `users` — единственной ручкой был `/users/me`, её роль играет `/auth/me` облака;
 *  - `prisma` — `PrismaModule` облака глобальный, свой клиент фактуре не нужен;
 *  - `health` — у облака свой `/healthz`.
 */
@Module({
  imports: [
    InvoicesModule,
    ContactsModule,
    ExpensesModule,
    DeclarationsModule,
    FiledDeclarationsModule,
    BankAccountsModule,
    TaxModule,
    CompaniesModule,
  ],
})
export class FacturaModule {}
