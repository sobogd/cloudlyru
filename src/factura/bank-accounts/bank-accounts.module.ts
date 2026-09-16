import { Module } from "@nestjs/common";
import { BankAccountsController } from "./bank-accounts.controller";

@Module({
  controllers: [BankAccountsController],
})
export class BankAccountsModule {}
