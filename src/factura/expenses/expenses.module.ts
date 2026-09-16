import { Module } from "@nestjs/common";
import { ExpensesController } from "./expenses.controller";
import { ExpenseDocStorageService } from "./expense-doc.storage";

@Module({
  controllers: [ExpensesController],
  providers: [ExpenseDocStorageService],
})
export class ExpensesModule {}
