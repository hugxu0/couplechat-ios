export interface ShutdownDependencies {
  stopSchedulers(): void;
  stopUploadCleanup(): void;
  closeSocket(): Promise<void>;
  closeHttp(): Promise<void>;
  closeDatabase(): Promise<void>;
}

export async function shutdownServer(dependencies: ShutdownDependencies): Promise<void> {
  dependencies.stopSchedulers();
  dependencies.stopUploadCleanup();
  await dependencies.closeSocket();
  await dependencies.closeHttp();
  await dependencies.closeDatabase();
}
