import { Module } from "@nestjs/common";
import { FiledDeclarationsController } from "./filed-declarations.controller";
import { FiledDeclarationDocStorageService } from "./filed-declaration-doc.storage";

@Module({
  controllers: [FiledDeclarationsController],
  providers: [FiledDeclarationDocStorageService],
})
export class FiledDeclarationsModule {}
