"""Apply reviewed terminology after translation drafts; remove stale catalog keys."""
from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]/'Resources/Localization'
source=json.loads((root/'zh-Hans.json').read_text())
source['跟随系统']='跟随系统'
reviewed={
 '运行引擎':('Engines','Moteurs','Motores'),
 '模型文件':('Model Files','Fichiers modèles','Arquivos de modelos'),
 '模型服务':('Services','Services','Serviços'),
 '下载导入':('Downloads & Import','Téléchargements','Downloads e importação'),
 '资源与性能':('Resources','Ressources','Recursos'),
 '模型管理':('ModelDock','ModelDock','ModelDock'),
 '关于模型管理':('About ModelDock','À propos de ModelDock','Sobre o ModelDock'),
 '退出模型管理':('Quit ModelDock','Quitter ModelDock','Sair do ModelDock'),
 '模型基座':('Engine','Moteur','Motor'),
 '草稿加速':('Draft acceleration','Décodage spéculatif','Decodificação especulativa'),
 '界面语言':('Interface language','Langue de l’interface','Idioma da interface'),
 '语言':('Language','Langue','Idioma'),
 '跟随系统':('Follow system','Suivre le système','Seguir o sistema'),
 '完成':('Done','Terminer','Concluir'),
 '已是最新':('Up to date','À jour','Atualizado'),
 '有新版本':('Update available','Mise à jour disponible','Atualização disponível'),
 '未安装':('Not installed','Non installé','Não instalado'),
 '启动服务':('Start service','Démarrer le service','Iniciar serviço'),
 '停止服务':('Stop service','Arrêter le service','Parar serviço'),
 '启动模型':('Start model','Démarrer le modèle','Iniciar modelo'),
 '已完成':('Completed','Terminé','Concluído'),
 '已暂停':('Paused','En pause','Pausado'),
 '下载中':('Downloading','Téléchargement','Baixando'),
 '全部':('All','Tous','Todos'),
 '主模型':('Main models','Modèles principaux','Modelos principais'),
 '附属模型':('Auxiliary models','Modèles auxiliaires','Modelos auxiliares'),
 '仅文本':('Text only','Texte uniquement','Apenas texto'),
 '运行中':('Running','En cours','Em execução'),
 '已完成 {0} / {1}':('Completed {0} / {1}','Terminés : {0} / {1}','Concluídos: {0} / {1}'),
}
for i,lang in enumerate(['en','fr','pt']):
 file=root/(lang+'.json');data=json.loads(file.read_text());data={k:data[k] for k in source if k in data}
 for key,values in reviewed.items():
  if key in source:data[key]=values[i]
 assert set(data)==set(source),(lang,'Missing keys',set(source)-set(data))
 file.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
source['模型管理']='模型坞'
(root/'zh-Hans.json').write_text(json.dumps(source,ensure_ascii=False,indent=2)+'\n')
print('Reviewed and synchronized',len(source),'messages in four languages')
