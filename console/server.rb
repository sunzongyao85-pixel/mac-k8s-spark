# encoding: UTF-8
require 'webrick'
require 'json'
require 'securerandom'
require 'open3'
require 'timeout'
require 'fileutils'
BASE=File.expand_path(__dir__)
PROJECT=File.expand_path('..',BASE)
TOKEN=SecureRandom.hex(32)
PORT=Integer(ENV.fetch('ACCEPTANCE_PORT','8765'))
ENVIRONMENT={'LIMA_HOME'=>ENV.fetch('LIMA_HOME',File.join(Dir.home,'.lima-mac-spark'))}
LIMA=File.join(PROJECT,'.tools/bin/limactl')
def kube(*args)
  [LIMA,'shell','spark-k3s','sudo','k3s','kubectl','--request-timeout=30s',*args]
end
ACTIONS={
  'environment'=>[['检查 macOS',['/usr/bin/uname','-sm'],0],['启动 Kubernetes',['./01-start-k8s.sh'],0]],
  'k8s'=>[['启动 Kubernetes',['./01-start-k8s.sh'],0]],
  'spark'=>[['部署 Spark',['./02-start-spark.sh'],0]],
  'check'=>[['检测 Spark',['./03-check-spark.sh'],0]],
  'inspect'=>[['查看节点',kube('get','nodes','-o','wide'),0],['查看 Spark Pod',kube('-n','spark-demo','get','pods','-o','wide'),0]],
  'failure'=>[['停止演示 Spark',kube('-n','spark-demo','scale','deployment/spark','--replicas=0'),0],['等待 Pod 停止',kube('-n','spark-demo','wait','--for=delete','pod','-l','app=spark','--timeout=60s','--request-timeout=90s'),0],['验证未就绪',['./03-check-spark.sh'],1]],
  'restore'=>[['恢复 Spark',['./02-start-spark.sh'],0]]
}
ACTIONS['all']=ACTIONS['environment']+ACTIONS['spark']+ACTIONS['check']+ACTIONS['inspect']
LOCK=Mutex.new
STATE={status:'idle',action:nil,steps:[],log:'',phase:'等待开始',started_at:nil,finished_at:nil,id:nil}
def append_log(s)
  LOCK.synchronize { STATE[:log] << s.encode('UTF-8',invalid: :replace,undef: :replace); STATE[:log]="[日志过长，仅保留最近部分]\n"+STATE[:log].chars.last(100_000).join if STATE[:log].bytesize>400_000 }
end
def run_job(action)
  Thread.new do
    begin
      ACTIONS.fetch(action).each_with_index do |(title,argv,expected),i|
        LOCK.synchronize { STATE[:steps][i][:status]='running'; STATE[:phase]=title+' · 执行中' }
        append_log("\n━━ #{title} ━━\n$ #{argv.join(' ')}\n")
        exit_code=nil
        Open3.popen2e(ENVIRONMENT,*argv,chdir:PROJECT,pgroup:true) do |stdin,out,wait|
          stdin.close
          begin
            Timeout.timeout(1800) do
              out.each_line do |line|
                append_log(line)
                phase=case line
                when /Downloading Lima/ then '正在下载 Lima 并校验组件'
                when /Attempting to download|Downloading the image/ then '正在准备 Linux 虚拟机镜像'
                when /Starting VZ|Starting the instance/ then '正在启动 Linux 虚拟机'
                when /Waiting for.*ssh/ then '正在等待虚拟机 SSH'
                when /Waiting for deployment "coredns"/ then '正在等待 CoreDNS 就绪'
                when /K8S_READY/ then 'Kubernetes 已就绪'
                when /Waiting for deployment "spark"/ then '正在等待 Spark 容器就绪'
                when /MASTER_ALIVE WORKER_REGISTERED/ then 'Master / Worker 已就绪，正在运行 SparkPi'
                when /SPARK_READY/ then 'Spark 计算验证通过'
                end
                LOCK.synchronize { STATE[:phase]=phase } if phase
              end
              exit_code=wait.value.exitstatus || 1
            end
          rescue Timeout::Error
            Process.kill('TERM',-wait.pid) rescue nil
            sleep 1
            Process.kill('KILL',-wait.pid) rescue nil
            exit_code=124
            append_log("执行超过 30 分钟，已终止本次命令。\n")
          end
        end
        passed=exit_code==expected
        append_log("[退出码 #{exit_code} / 预期 #{expected}] #{passed ? '通过' : '失败'}\n")
        LOCK.synchronize { STATE[:steps][i].merge!(status:passed ? 'passed' : 'failed',exit_code:exit_code) }
        raise '命令结果不符合预期，后续步骤未执行。' unless passed
      end
      LOCK.synchronize { STATE[:status]='passed'; STATE[:phase]=action=='failure' ? '故障检测通过 · Spark 当前已停止，请点击恢复' : '本轮执行通过' }
    rescue => e
      append_log("ERROR: #{e.message}\n")
      LOCK.synchronize do
        STATE[:status]='failed'; STATE[:phase]='执行失败 · 请查看终端输出'
        STATE[:steps].each { |s| s[:status]='failed' if s[:status]=='running' }
      end
    ensure
      snapshot=LOCK.synchronize do
        STATE[:finished_at]=Time.now.iso8601
        STATE[:steps].each { |s| s[:status]='skipped' if s[:status]=='pending' }
        JSON.pretty_generate(STATE)
      end
      dir=File.join(PROJECT,'evidence','ui-runs'); FileUtils.mkdir_p(dir)
      File.write(File.join(dir,JSON.parse(snapshot)['id']+'.json'),snapshot)
    end
  end
end
require 'time'
server=WEBrick::HTTPServer.new(Port:PORT,BindAddress:'127.0.0.1',AccessLog:[],Logger:WEBrick::Log.new($stderr,WEBrick::Log::WARN))
server.mount_proc('/') do |req,res|
  res['Cache-Control']='no-store'; res['X-Content-Type-Options']='nosniff'; res['X-Frame-Options']='DENY'
  unless ["127.0.0.1:#{PORT}","localhost:#{PORT}"].include?(req['host'])
    res.status=403; res.body='Invalid host'; next
  end
  case [req.request_method,req.path]
  when ['GET','/']
    res['Content-Type']='text/html; charset=utf-8'
    res.body=File.read(File.join(BASE,'index.html'),encoding:'UTF-8').sub('/*SERVER_CONFIG*/',"window.SERVER_CONFIG={token:#{TOKEN.to_json}};")
  when ['GET','/api/state']
    res['Content-Type']='application/json; charset=utf-8'; res.body=LOCK.synchronize{JSON.generate(STATE)}
  when ['POST','/api/run']
    res['Content-Type']='application/json; charset=utf-8'
    origin=req['origin']
    unless req['x-acceptance-token']==TOKEN && (origin.nil? || ["http://127.0.0.1:#{PORT}","http://localhost:#{PORT}"].include?(origin))
      res.status=403; res.body='{"error":"请求未授权，请从本地控制台操作。"}'; next
    end
    begin
      data=JSON.parse(req.body || '{}'); action=data['action']
      raise ArgumentError,'未知验收项' unless ACTIONS.key?(action)
      accepted=LOCK.synchronize do
        if STATE[:status]=='running' || (STATE[:id] && STATE[:finished_at].nil?)
          false
        else
          STATE.replace(status:'running',action:action,phase:'正在准备执行',steps:ACTIONS[action].map{|title,argv,expected|{title:title,command:argv.join(' '),expected:expected,status:'pending',exit_code:nil}},log:'',started_at:Time.now.iso8601,finished_at:nil,id:Time.now.strftime('%Y%m%d-%H%M%S')+'-'+SecureRandom.hex(3)); true
        end
      end
      if accepted
        run_job(action);res.body='{"ok":true}'
      else
        res.status=409;res.body='{"error":"已有任务执行中，请等待完成。"}'
      end
    rescue JSON::ParserError,ArgumentError => e
      res.status=400;res.body={error:e.message}.to_json
    end
  when ['GET','/history']
    res['Content-Type']='text/html; charset=utf-8';res.body=File.read(File.join(PROJECT,'docs','report.html'),encoding:'UTF-8')
  else
    # Only explicitly public deliverables can be read; never expose .tools or VM keys.
    permitted={'/README.md'=>'README.md','/docs/TEST-REPORT.md'=>'docs/TEST-REPORT.md'}
    path=permitted[req.path]
    if req.request_method=='GET' && path
      res['Content-Type']=path.end_with?('.zip') ? 'application/zip' : 'text/plain; charset=utf-8';res.body=File.binread(File.join(PROJECT,path))
    else
      res.status=404;res.body='Not found'
    end
  end
end
trap('INT'){server.shutdown};trap('TERM'){server.shutdown}
puts "验收控制台已启动：http://127.0.0.1:#{PORT}"
$stdout.flush
server.start
