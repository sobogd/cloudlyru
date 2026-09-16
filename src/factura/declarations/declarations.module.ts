import { Module } from "@nestjs/common";
import { DeclarationsController } from "./declarations.controller";
import { DeclarationsService } from "./declarations.service";

@Module({
  controllers: [DeclarationsController],
  providers: [DeclarationsService],
})
export class DeclarationsModule {}
