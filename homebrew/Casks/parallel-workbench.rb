cask "parallel-workbench" do
  version "0.2.1"
  sha256 :no_check

  # GitHub 仓库：HanchengQiao/parallel-workshop
  url "https://github.com/HanchengQiao/parallel-workshop/releases/download/v#{version}/ParallelWorkbench-#{version}.dmg"
  name "平行工作台"
  name "Parallel Workbench"
  desc "多模型平行问答工作台：一次提问，多个 AI 平台并排回答"
  homepage "https://github.com/HanchengQiao/parallel-workshop"

  app "ParallelWorkbench.app"
end
