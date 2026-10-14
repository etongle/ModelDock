(() => {
  const copy = {
    en: {
      skip:'Skip to content', navHow:'How it works', navGuide:'User guide', eyebrow:'Native macOS · Apple Silicon',
      heroTitle:'Local AI.<br>One place to run it.', heroCopy:'Your engines, model files, downloads and services—together in a native Mac app. Choose a model, configure its capabilities, and connect the tools you already use.',
      download:'Get ModelDock <span aria-hidden="true">↓</span>',readGuide:'Read the guide <span aria-hidden="true">→</span>',requirements:'Apple Silicon · macOS 14+ · Noncommercial use',windowTitle:'Your model workspace',demoCaption:'Screenshots use demonstration data. Sizes and resource values are illustrative.',
      workflowEye:'From files to a working endpoint',workflowTitle:'A clear path to your next model.',workflowCopy:'Keep the model, the runtime and the service distinct. Manage each without losing track of the others.',
      stepDownload:'Download & inspect',stepDownloadCopy:'Resolve a repository ID, choose files, resume a task, and inspect progress one file at a time.',stepModel:'Choose the right runtime',stepModelCopy:'See compatible engines, check files, and configure text or supported multimodal input.',stepService:'Run & connect',stepServiceCopy:'Use independent ports and instances. Connect pi or OpenCode directly or through the gateway.',
      captionDownloads:'A repository checkbox selects a file; the task detail confirms its download status.',captionModels:'Check compatibility and choose a launch configuration for the selected model.',captionServices:'Each service instance has its own model, endpoint and launch settings.',
      controlEye:'Stay in control',controlTitle:'Big downloads.<br>Small, clear decisions.',controlCopy:'Pause one file to make room for another. Keep old model revisions for later switching. Review cleanup before removing files.',controlOne:'Per-task and per-file progress, percentages and transfer speed.',controlTwo:'Task deletion preserves files; incomplete-file cleanup is a separate action.',controlThree:'Running models and shared auxiliary files receive deletion protection.',detailCaption:'Pause a file or prioritize another while keeping resumable data.',
      engineEye:'Use a compatible engine',engineTitle:'One manager. Different runtimes.',engineCopy:'Input capabilities depend on the model, its auxiliary components, and the actual runtime version.',engineCol:'Engine',formatCol:'Models',inputCol:'How it runs',splashModels:'Compatible upstream MLX; matching legacy packed models',splashInput:'Text; supported current assemblies can include images/PDFs and matched drafts',llamaInput:'Text or supported media with a matching projector',mlxInput:'LM for text; VLM for supported multimodal architectures',ollamaModels:'Ollama-registered models',ollamaInput:'Native model lifecycle and per-model capabilities',studioInput:'Load through the application or its supported CLI',prismInput:'Support depends on the local build and model architecture',strataModels:'External compatible API',strataInput:'Connect an upstream service; native Mac installation is not bundled',
      gatewayEye:'Bring your own client',gatewayTitle:'Direct connection.<br>Or one shared gateway.',gatewayCopy:"Register a ready model in pi or OpenCode. Use its own endpoint, or route local services and remote compatible APIs through ModelDock's gateway.",gatewayLink:'See the connection guide →',otherClient:'Your client',gatewayNode:'ModelDock gateway',localRoute:'Local services',remoteRoute:'Remote APIs',directNote:'Direct service endpoints remain available.',
      languageEye:'Make it yours',languageTitle:'English by default.<br>Switch when you want.',languageCopy:'Use the globe/language button at the top right to choose English, Simplified Chinese, French, Portuguese or system language. The interface updates immediately; Settings also keeps the language option.',menuTitle:'Keep the window closed.',menuCopy:'Watch system resources and downloads from the menu bar. Click outside the panel to dismiss it; reopen the manager when needed.',
      licenseEye:'Source available · Noncommercial',licenseTitle:'Explore it. Learn from it.<br>Keep it noncommercial.',licenseCopy:'First-party code and documentation use PolyForm Noncommercial 1.0.0. Permitted noncommercial use, modification and redistribution are allowed; commercial use is not granted. Third-party engines and models keep their own terms.',licenseLink:'Read the license ↗',finalTitle:'Give your models a home.',source:'View the source ↗',installNote:'Current releases are not Apple-notarized. See the installation guide before opening a downloaded copy.',footer:'Made for local AI on Mac. Source-available, for noncommercial purposes.'
    },
    zh: {
      skip:'跳至正文',navHow:'使用流程',navGuide:'使用说明',eyebrow:'原生 macOS · Apple Silicon',heroTitle:'本地模型。<br>一处掌控。',heroCopy:'把运行引擎、模型文件、下载任务和服务放进一个原生 Mac 应用。选好模型，配置输入能力，接入你常用的工具。',download:'下载 ModelDock <span aria-hidden="true">↓</span>',readGuide:'阅读使用说明 <span aria-hidden="true">→</span>',requirements:'Apple Silicon · macOS 14+ · 非商业使用',windowTitle:'你的模型工作空间',demoCaption:'截图使用示例数据。模型大小和资源数值仅用于说明界面。',
      workflowEye:'从模型文件到可用接口',workflowTitle:'下一个模型，按步骤准备。',workflowCopy:'分别管理模型、运行时和服务，每一步都能看到明确的状态。',stepDownload:'下载与检查',stepDownloadCopy:'解析仓库 ID、选择文件、续传任务，逐个查看文件进度。',stepModel:'选择兼容基座',stepModelCopy:'查看适配引擎，检查文件，配置纯文本或模型支持的多模态。',stepService:'运行与接入',stepServiceCopy:'使用独立端口和实例，直接或通过统一网关接入 pi、OpenCode。',captionDownloads:'勾选表示选择下载，是否完成要在任务详情中确认。',captionModels:'核对兼容情况，为选中的模型配置启动方式。',captionServices:'每个服务实例都有自己的模型、接口地址和启动设置。',
      controlEye:'掌握下载与文件',controlTitle:'模型文件很大。<br>每个操作很清楚。',controlCopy:'暂停某个文件，让其他文件先下载。保留旧模型版本供后续切换，清理前先核对范围。',controlOne:'任务与单文件进度、百分比、传输速度。',controlTwo:'删除任务保留文件；清理未完成文件是独立操作。',controlThree:'运行中的模型和共用辅助文件受到删除保护。',detailCaption:'暂停文件或优先下载其他文件，保留可续传的数据。',
      engineEye:'选择适配的引擎',engineTitle:'一个管理工具，多种运行基座。',engineCopy:'输入能力取决于模型、配套组件和实际运行时版本。',engineCol:'基座',formatCol:'模型',inputCol:'运行方式',splashModels:'兼容的上游 MLX；匹配的旧 packed 模型',splashInput:'文本；适配的新版组合支持图片/PDF 与匹配草稿',llamaInput:'文本；支持的多模态需匹配投影组件',mlxInput:'LM 用于文本，VLM 用于支持的多模态架构',ollamaModels:'已登记的 Ollama 模型',ollamaInput:'使用原生模型管理，能力依具体模型而定',studioInput:'在原应用或支持的命令行中加载',prismInput:'支持情况取决于本地构建和模型架构',strataModels:'外部兼容 API',strataInput:'接入上游服务；当前未内置原生 Mac 安装方式',
      gatewayEye:'连接你常用的客户端',gatewayTitle:'直接连接。<br>也可统一接入。',gatewayCopy:'将就绪模型登记到 pi 或 OpenCode。使用独立服务地址，或把本机服务、远程兼容 API 接入模型坞网关。',gatewayLink:'查看客户端接入说明 →',otherClient:'其他客户端',gatewayNode:'ModelDock 统一网关',localRoute:'本机模型服务',remoteRoute:'远程 API',directNote:'独立服务仍可直接连接。',
      languageEye:'按自己的习惯使用',languageTitle:'默认英语。<br>语言随时切换。',languageCopy:'点击主界面右上角的地球/语言按钮，选择英语、简体中文、法语、葡萄牙语或跟随系统，界面立即更新。设置中也保留语言选项。',menuTitle:'主窗口可以关着。',menuCopy:'在菜单栏查看资源和下载状态，点击面板外部自动收起，需要时再打开管理界面。',licenseEye:'源码可见 · 非商业许可',licenseTitle:'可以探索与学习。<br>限于非商业用途。',licenseCopy:'第一方代码和文档采用 PolyForm Noncommercial 1.0.0，允许规定的非商业使用、修改与再分发，没有授予商业使用许可。第三方基座及模型保持各自条款。',licenseLink:'阅读许可原文 ↗',finalTitle:'给你的模型一个停靠处。',source:'查看源码 ↗',installNote:'当前发行包尚未通过 Apple 公证，首次打开前请参考安装说明。',footer:'为 Mac 本地模型管理而做。源码可见，限于非商业用途。'
    }
  };
  let lang='en', tab='downloads';
  const page=document.body.dataset.page;
  try {lang=page==='guide'?document.body.dataset.language:(localStorage.getItem('modeldock-language')||'en')}catch{}
  if(!copy[lang])lang='en';
  function updateTab(next,focus=false){
    tab=next;
    const tabs=[...document.querySelectorAll('[data-tab]')];
    for(const node of tabs){const selected=node.dataset.tab===tab;node.classList.toggle('active',selected);node.setAttribute('aria-selected',String(selected));node.tabIndex=selected?0:-1;if(selected&&focus)node.focus()}
    const image=document.getElementById('workflow-image');
    if(image){image.src=`assets/${lang==='zh'?'zh-Hans':'en'}-${tab}.png`;image.alt=copy[lang][{downloads:'captionDownloads',models:'captionModels',services:'captionServices'}[tab]];document.getElementById('workflow-panel').setAttribute('aria-labelledby',{downloads:'step-download',models:'step-model',services:'step-service'}[tab]);document.getElementById('workflow-caption').textContent=image.alt}
  }
  function apply(){
    document.documentElement.lang=lang==='zh'?'zh-Hans':'en';
    for(const element of document.querySelectorAll('[data-i18n]')){const value=copy[lang][element.dataset.i18n];if(value!==undefined)element.innerHTML=value}
    const button=document.getElementById('language');if(button){button.textContent=lang==='en'?'中文':'English';button.setAttribute('aria-label',lang==='en'?'Switch to Simplified Chinese':'Switch to English')}
    for(const link of document.querySelectorAll('.guide-link'))link.href=lang==='zh'?'guide.zh-CN.html':'guide.html';
    const prefix=lang==='zh'?'zh-Hans':'en';
    const hero=document.getElementById('hero-image');if(hero){hero.src=`assets/${prefix}-engines.png`;hero.alt=lang==='zh'?'模型坞运行引擎与兼容模型界面':'ModelDock engines and compatible model selection'}
    const detail=document.getElementById('detail-image');if(detail){detail.src=`assets/${prefix}-download-files.png`;detail.alt=lang==='zh'?'逐个文件的下载进度和暂停操作':'Per-file download progress and pause controls'}
    updateTab(tab);
    try {localStorage.setItem('modeldock-language',lang)}catch{}
  }
  document.getElementById('language')?.addEventListener('click',()=>{lang=lang==='en'?'zh':'en';if(page==='guide'){try{localStorage.setItem('modeldock-language',lang)}catch{}location.href=lang==='zh'?'guide.zh-CN.html':'guide.html'}else apply()});
  const tabs=[...document.querySelectorAll('[data-tab]')];
  for(const element of tabs){element.addEventListener('click',()=>updateTab(element.dataset.tab));element.addEventListener('keydown',event=>{if(!['ArrowRight','ArrowLeft','Home','End'].includes(event.key))return;event.preventDefault();let index=tabs.indexOf(element);index=event.key==='Home'?0:event.key==='End'?tabs.length-1:(index+(event.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;updateTab(tabs[index].dataset.tab,true)})}
  apply();
})();
