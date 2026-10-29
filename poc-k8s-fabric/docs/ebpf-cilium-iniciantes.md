# eBPF e Cilium sem mistério
## fundamentos e laboratório guiado para iniciantes
**Autor:** Learn Cilium · **Local:** Teresina · **Ano:** 2026 · **Edição:** 0.2 de trabalho · **Público-alvo:** iniciantes em Linux, redes e Kubernetes

## Apresentação

Começamos por três perguntas: onde um comando roda, por onde uma conexão passa e que evidência ajuda a localizar uma falha? C01–C03 apresentam Linux, rede e Kubernetes. Depois, E01–E06 levam do reconhecimento do ambiente à cadeia de aplicações, observação, controle de tráfego, diagnóstico e limpeza.

**Como usar:** há dois modos para a mesma prática. No modo guiado, siga os passos E01 a E06 com apoio. No modo de revisão, leia os requisitos dos laboratórios A, B e C e tente produzir as evidências antes de consultar os passos correspondentes ou as soluções. A preparação do ambiente em E01 e a limpeza em E06 continuam assistidas pelo instrutor; pedir ajuda ou consultar a orientação não é reprovação.

Os dois modos usam uma só rodada, uma namespace e o mesmo recibo. Não é preciso dominar Bash nem entender a função `record` para usar os exercícios. Depois da limpeza, as soluções interpretam o recibo já preenchido; não iniciam outra rodada. Antes de cada exercício, estude a figura e anote uma previsão. “Esperado — ILUSTRATIVO” descreve um resultado possível. “NOT_RUN — ainda não executado” marca observações que só podem ser preenchidas depois de uma prática autorizada.

**Edição de trabalho:** os comandos e arquivos do laboratório não foram reproduzidos em cluster; nenhuma imagem instalada, tráfego observado, aprendizagem de leitor ou validação operacional é afirmada. Cilium stable 1.20.4 é uma referência consultada em 28 de outubro de 2026, não uma versão instalada. (Cilium Authors, 2026)

~~~{=latex}
\makeatletter
\LetLtxMacro\guiaPdfBookmarkOriginal\pdfbookmark
\renewcommand{\pdfbookmark}[3][0]{%
  \def\guiaBookmarkDestination{#3}%
  \def\guiaSuppressLoq{loq}%
  \def\guiaSuppressLot{lot}%
  \ifx\guiaBookmarkDestination\guiaSuppressLoq
  \else\ifx\guiaBookmarkDestination\guiaSuppressLot
  \else\guiaPdfBookmarkOriginal[#1]{#2}{#3}%
  \fi\fi}
\def\listofquadros{\@ifstar{\relax}{\relax}}
\def\listoftables{\@ifstar{\relax}{\relax}}
\makeatother
~~~

~~~{=latex}
\RecustomVerbatimEnvironment{verbatim}{Verbatim}{breaklines,breakanywhere,fontsize=\normalsize,frame=single,framesep=2mm}
~~~

~~~{=latex}
\clearpage
~~~

## Módulo 1 — C01 · Linux sem medo

### 1.1 Por que começar pelo Linux

O Linux é o sistema operacional no qual o Cilium integra boa parte de sua rede. Entender onde termina um processo e começa o kernel evita tratar cada contêiner como uma máquina independente. Neste capítulo, você vai:

- distinguir um processo, o kernel e o sistema de arquivos usado por um contêiner;
- explicar para que servem namespaces e cgroups sem supor que um contêiner tem um kernel próprio;
- localizar comandos no computador, na VM Linux e em um Pod e interpretar seu resultado.

**Pré-requisitos:** nenhum. Não é preciso abrir terminal ou ter um cluster para ler os exemplos.

### 1.2 Palavras antes do jargão

O **kernel** é o núcleo que administra CPU, memória, dispositivos e chamadas de sistema. Um **processo** é um programa em execução, com um identificador e recursos associados. Um **contêiner** organiza um ou mais processos com uma visão isolada de recursos do Linux; ele usa o kernel do sistema que o hospeda. **Namespaces** alteram a visão de recursos como processos, rede e montagem de arquivos. **Cgroups** organizam e medem recursos de grupos de processos. Esses recursos ajudam a formar contêineres, mas não transformam cada contêiner em uma máquina virtual completa. (Linux man-pages project, 2026)

Uma **máquina virtual** inclui um sistema operacional convidado e seu próprio kernel virtualizado. Um contêiner Linux comum compartilha o kernel Linux do host. Uma analogia limitada: apartamentos compartilham partes de um prédio, enquanto cada morador tem um espaço próprio. A analogia para nos limites das diferenças entre um prédio físico e as regras técnicas de namespaces, cgroups e sistema de arquivos; não descreve o mecanismo de segurança completo.

**Figura 1 – Linux separa processo, kernel, contêiner e lugar de execução**

![O computador pessoal contém uma VM Linux autorizada com terminal, Bash, cliente kubectl e kernel Linux da VM. Uma caixa separada representa o API server que recebe a chamada. No nó Linux do cluster, o Pod frontend contém o processo curl executado depois de --; namespaces isolam uma visão e cgroups organizam recursos. A seta liga a chamada da VM ao processo remoto, que usa o kernel do nó.](diagramas/ebpf-cilium-iniciantes/figura-04-linux-contextos.png)

Fonte: elaboração própria (2026), com base em (Linux man-pages project, 2026), (Kubernetes Authors, 2026) e no roteiro E01.\
Nota: é um modelo didático, não um diagrama de um cluster medido.

```{=latex}
\FloatBarrier
```

### 1.3 Terminal, shell e comandos

Um **terminal** é a interface onde você digita e lê texto. Um **shell**, como Bash, interpreta essa linha e chama programas. Uma **variável** guarda um valor durante a sessão; escrever LAB_NS=valor atribui um valor ao nome LAB_NS, e $LAB_NS pede o valor guardado. Aspas duplas mantêm junto um valor que tenha espaços e deixam variáveis serem expandidas. Aspas simples preservam o conteúdo literalmente. A barra / separa diretórios e também aparece em URLs e caminhos; seu significado depende do contexto. O escape com barra invertida muda como o shell interpreta o próximo caractere. (GNU Project, 2025)

Um **código de saída** é o número que o comando devolve ao shell: zero costuma indicar conclusão sem erro para aquele comando; valor diferente de zero indica falha segundo o próprio programa. Isso não é o mesmo que um código HTTP. Com `curl --fail-with-body`, uma resposta HTTP de erro também faz curl devolver código diferente de zero; sem a opção, curl pode terminar com código zero mesmo ao receber HTTP 502. Registre os dois sinais quando ambos existirem. (GNU Project, 2025)

A tecla **Ctrl-C** envia uma interrupção ao comando em primeiro plano daquele terminal. No exercício E03, a porta encaminhada roda em outro terminal; Ctrl-C nele encerra somente aquele encaminhamento. Não pressione Ctrl-C em um terminal que esteja aplicando ou apagando recursos.

### 1.4 Exemplo e perguntas

Leia os locais:

- HOST: computador pessoal. O kernel pode ser macOS; comandos Linux não ganham um kernel Linux por serem executados aqui.
- VM Linux: convidado Linux que tem o cliente kubectl e acessa o API server com a identidade fornecida.
- POD: unidade Kubernetes que reúne contêineres e compartilha uma identidade de rede local entre eles.
- processo no frontend: o curl executa no contêiner, mas kubectl exec é enviado pela VM ao API server.

**Perguntas para recordar**

1. Um contêiner Linux padrão tem um kernel próprio?
2. O que namespaces e cgroups organizam?
3. Onde roda o comando depois de `kubectl exec ... --`?
4. Se curl devolveu código 22, isso informa diretamente o código HTTP exato?

**Gabarito comentado:** (1) não; um contêiner Linux comum compartilha o kernel Linux do host. (2) namespaces organizam visões de recursos; cgroups organizam e acompanham recursos de grupos de processos. (3) no contêiner e no Pod selecionados, não no shell da VM. (4) não; o código 22 sinaliza uma classe de resposta HTTP não bem-sucedida em curl, enquanto o status HTTP deve ser lido nos cabeçalhos. Um código de saída descreve o resultado reportado pelo processo, não substitui a evidência da aplicação.

**Atividade guiada — 5 minutos, sem cluster:** classifique cada ação como HOST, VM ou POD e diga se o número observado é código de saída ou status HTTP: (A) abrir um terminal no computador pessoal; (B) executar `kubectl get pods`; (C) interpretar o padrão esquemático abaixo; (D) ler o `HTTP/1.1 200` impresso por curl. Anote também qual linha atravessa o API server.

~~~text
kubectl exec ... -- curl http://api/
~~~

Os pontos representam o nome do Pod; não copie a linha como um comando pronto.

**Resultado esperado — ILUSTRATIVO:** A ocorre no HOST; B ocorre na VM e conversa com o API server; C é iniciado na VM, mas o processo curl roda no POD; D é um status HTTP, não o código de saída. Nenhum cluster é necessário para completar a classificação.

**Prática integrada C01→E01 — estimativa preliminar de 15–25 minutos, não medida:** E01 aplica o mapa HOST/VM/POD, variáveis e aspas, código de saída e a regra de parar diante de uma identidade divergente. O tempo real depende da preparação do instrutor e das respostas do ambiente.

**Erro comum:** executar um comando no lugar errado e interpretar a falha como problema de rede. Antes de qualquer comando, diga em voz alta: “host, VM ou Pod?”

**Resumo:** o kernel executa processos; contêineres usam mecanismos de isolamento sobre um kernel; o shell interpreta comandos; local de execução e código de saída fazem parte do diagnóstico.

**Glossário consultável**

- **Kernel:** núcleo do sistema operacional.
- **Processo:** programa em execução.
- **Contêiner:** ambiente organizado para processos.
- **Namespace Linux:** visão isolada de certos recursos do sistema.
- **Cgroup:** agrupamento e controle de recursos.
- **Terminal:** interface de texto.
- **Shell:** intérprete de comandos.
- **Variável:** nome que guarda um valor.
- **Código de saída:** resultado do comando informado ao shell.

**Leituras:** namespaces e cgroups no Linux; segurança de contêineres e contextos de segurança no Kubernetes; Bash: expansão, aspas e status de saída.

## Módulo 2 — C02 · Uma conversa pela rede

### 2.1 Seguir a ida e a volta

Uma aplicação conversa com outra usando nomes, endereços, portas e protocolos. Neste capítulo, você vai:

- diferenciar nome DNS, endereço IP, bloco CIDR e porta;
- narrar em ordem a resolução de nome, a abertura TCP e as formas de encerrar ou interromper uma conexão;
- explicar que uma resposta HTTP retorna pela conexão e que o caminho concreto depende do ambiente.

**Pré-requisitos:** reconhecer o shell, o processo e a VM Linux do C01. Não é necessário calcular sub-redes à mão.

### 2.2 Termos sem atalhos

Um **nome DNS** é um nome consultado para encontrar dados associados, como o endereço de um Service Kubernetes. **DNS** responde a uma consulta de nome; não carrega por si só o conteúdo HTTP. Um **endereço IP** identifica um destino na rede durante determinado escopo e tempo. **CIDR** escreve um endereço seguido do tamanho do prefixo de rede, por exemplo 10.20.0.0/24; /24 conta bits do prefixo, não indica uma porta. Um **pacote** transporta dados e cabeçalhos de protocolos em camadas.

Uma **porta TCP** identifica um ponto de comunicação dentro de um host de rede; não é um endereço IP. **TCP** estabelece uma conexão confiável entre extremos. **HTTP** descreve pedidos e respostas de aplicação carregados sobre uma conexão; método, caminho e status pertencem a HTTP, não ao endereço DNS. (IETF, 1987) (IETF, 2006) (IETF, 2022)

No Kubernetes, um **Service** oferece um destino lógico para Pods selecionados. O cliente usa a porta do Service; **targetPort** indica a porta dos contêineres para a qual o Service encaminha. Uma **namespace Kubernetes** agrupa nomes de muitos objetos; ela é diferente da namespace Linux do C01 e não isola sozinha todo o cluster. (Kubernetes Authors, 2026)

**SYN** participa da abertura TCP; **ACK** confirma dados ou controles recebidos; **FIN** informa que aquele lado não enviará mais dados nessa conexão; **RST** sinaliza uma interrupção. Depois de enviar FIN, o lado ainda pode receber dados enquanto o outro lado não encerra o próprio envio. RST não é uma etapa do fechamento normal, e seu efeito depende do estado TCP. (IETF, 2022)

**Figura 2 – Um nome, um endereço e uma conexão carregam informações diferentes**

![Quatro painéis: A separa enlace, IP, TCP e HTTP; B mostra o exemplo CIDR 10.20.0.0/24 e seus 24 bits de prefixo; C liga o nome DNS api ao Service na porta 80 e targetPort 8080; D mostra o tempo descendo entre A, cliente, e B, servidor: SYN A→B, SYN-ACK B→A e ACK A→B abrem TCP; FIN A→B, ACK B→A, FIN B→A e ACK A→B fecham o envio de cada lado; um painel separado mostra RST A→B como interrupção alternativa, não como etapa após FIN. É uma sequência didática, não uma captura.](diagramas/ebpf-cilium-iniciantes/figura-05-rede-cidr-dns-tcp-http.png)

Fonte: elaboração própria (2026), com base em (IETF, 1987), (IETF, 2006), (IETF, 2022) e (Kubernetes Authors, 2026).\
Nota: endereços e prefixos são ilustrativos; IPs de Pod não são universais.

```{=latex}
\FloatBarrier
```

### 2.3 Um endereço lógico não é o caminho inteiro

No laboratório, o cliente pergunta por api. O DNS do cluster pode resolver esse nome para o Service api no namespace atual. O Service representa um destino lógico estável para o cliente; a rede do cluster encaminha a conexão para um Pod elegível. O endereço IP concreto do Pod e o mecanismo que o alcança dependem do cluster e do CNI, interface pela qual componentes de rede configuram a rede dos Pods. Não calcule nem fixe IP de Pod no roteiro. (Kubernetes Authors, 2026)

O Service da API recebe na porta 80 e encaminha ao contêiner na porta 8080. A API NGINX aceita a conexão e abre outra conexão ao Service backend na porta 80; esse Service encaminha ao processo httpd do backend na porta 8080. A resposta volta pela conexão de cada trecho. “Porta 80 para 8080” descreve o mapeamento do Service deste exemplo; não declara uma regra universal do Cilium. (Kubernetes Authors, 2026)

TCP costuma começar com SYN, SYN-ACK e ACK. Esse handshake abre a conexão; não é uma confirmação de que HTTP funcionará. A aplicação ainda pode responder 404, 502 ou outro status. Uma conexão pode ser bloqueada antes de haver resposta HTTP. Em sentido contrário, uma resposta HTTP pode chegar e ainda indicar erro de aplicação. Em HTTP/1.1, conexões podem persistir; receber uma resposta HTTP não significa, por si só, que TCP foi fechado. (IETF, 2022)

No fechamento normal ilustrado, A envia FIN para encerrar seu envio; B confirma com ACK e ainda pode enviar dados. Quando B terminar, envia FIN no sentido contrário, e A confirma com ACK. Assim, cada FIN encerra o envio em uma direção. Algumas mensagens de controle podem ser combinadas; a figura separa os passos para facilitar a leitura. Um RST pode interromper a conexão em vez desse fechamento ordenado; não é o passo seguinte ao par de FINs, e a validade da interrupção depende do estado TCP. Este é um modelo didático, não uma sequência universal. (IETF, 2022)

Uma analogia limitada: DNS se parece com consultar um catálogo para obter um endereço; TCP se parece com abrir uma conversa de ida e volta; HTTP é o formato combinado para pedir e responder. A analogia ajuda a separar etapas, mas não descreve encaminhamento de pacotes, balanceamento de Service ou regras de tráfego.

**Atividade guiada — 7 minutos, sem cluster:** use o cenário fixo do laboratório e trace `frontend → api:80 → Pod api:8080 → backend:80 → Pod backend:8080`. Marque onde ocorre DNS, quais Services recebem na porta 80, quais contêineres recebem na 8080 e onde NGINX abre uma segunda conexão. Depois desenhe uma seta de resposta para cada conexão. Em duas linhas do tempo, ordene a abertura `SYN A→B`, `SYN-ACK B→A`, `ACK A→B` e o fechamento `FIN A→B`, `ACK B→A`, `FIN B→A`, `ACK A→B`. Marque qual lado ainda pode receber dados depois do primeiro FIN. Em um cartão separado, desenhe `RST A→B` e anote que ele interrompe, sem colocá-lo depois do fechamento normal.

**Resultado esperado — ILUSTRATIVO:** os nomes `api` e `backend` identificam Services; cada Service recebe na porta 80 e encaminha para a porta 8080 do Pod selecionado. O frontend abre a primeira conexão com a API; NGINX abre a segunda com backend. Cada resposta percorre sua conexão de volta. Isso é o modelo dos manifests, não uma medição do cluster.

**Prática integrada C02→E02 — estimativa preliminar de 15–25 minutos, não medida:** E02 aplica DNS, Service, portas, duas conexões TCP e resposta HTTP ao caminho dos manifests. A estimativa exclui espera extraordinária por imagem ou assistência e não é um tempo observado.

~~~{=latex}
\clearpage
~~~

**Perguntas para recordar**

1. O que /24 mede em 10.20.0.0/24?
2. DNS transporta o corpo da resposta HTTP?
3. Qual é a diferença entre porta do Service e targetPort neste laboratório?
4. SYN, SYN-ACK e ACK abrem ou fecham a conexão?
5. No fechamento normal, o que cada FIN encerra? Onde entra um RST?

**Gabarito comentado:** (1) 24 bits do prefixo da rede. (2) não; DNS responde consultas de nome e a conversa HTTP usa uma conexão posterior. (3) o cliente chama o Service na 80; o Service direciona ao contêiner na 8080. (4) abrem. (5) FIN encerra o envio de quem o envia; o outro lado confirma e ainda pode enviar até mandar seu próprio FIN. RST é uma interrupção alternativa, não uma etapa depois do fechamento normal, e depende do estado TCP. As portas e IPs devem ser lidos no contexto e não copiados como valores universais.

**Erro comum:** dizer “o DNS falhou” quando o nome resolveu, mas o Service não tem endpoint pronto. Separar consulta DNS, conexão TCP, rota até o destino e resposta HTTP produz hipóteses diferentes.

**Resumo:** DNS resolve nomes; IPs identificam destinos; CIDR descreve prefixos; TCP abre conexões, pode encerrá-las por direção com FIN ou interrompê-las com RST; HTTP troca pedidos e respostas sem determinar sozinho quando TCP fecha.

**Glossário consultável**

- **DNS:** sistema de nomes que responde a consultas.
- **Endereço IP:** endereço de rede usado para localizar um destino.
- **CIDR:** endereço acompanhado do tamanho do prefixo de rede.
- **Porta:** identificador de comunicação TCP ou UDP.
- **SYN:** controle usado na abertura TCP.
- **ACK:** confirmação de dados ou controles recebidos.
- **FIN:** encerramento do envio em uma direção.
- **RST:** interrupção TCP.
- **HTTP:** protocolo de pedidos e respostas de aplicação.
- **Status HTTP:** resultado informado pela resposta da aplicação.

**Leituras:** RFC 1034 (DNS); RFC 4632 (CIDR); RFC 9110 (HTTP Semantics); RFC 9293 (TCP); DNS e Services no Kubernetes.

## Módulo 3 — C03 · Kubernetes em tamanho pequeno

### 3.1 Objetivos e objetos que se encontram

Kubernetes descreve o estado desejado por objetos. Um **cluster** contém o plano de controle e nós que executam Pods. Um **Pod** é a unidade programada no nó; contêineres do mesmo Pod compartilham rede local. Um **Deployment** pede réplicas de Pods e as mantém. Uma **label** é uma chave e valor que identifica um objeto; um **selector** escolhe objetos que têm as labels correspondentes. Label ajuda a agrupar, não autentica uma pessoa ou workload. (Kubernetes Authors, 2026)

Um **Service** fornece um nome e destino lógico para um conjunto selecionado de Pods. Uma **EndpointSlice** registra partes dos destinos de rede associados ao Service, incluindo endereços e condições como pronto ou encerrando. Um **CNI** integra a configuração de rede dos Pods; Cilium é o CNI já instalado neste roteiro. **NetworkPolicy** declara comunicações permitidas para Pods selecionados. **ConfigMap** entrega configuração não secreta. **Probe** é uma verificação periódica de uma aplicação; readiness influencia se o Pod recebe tráfego de Service, enquanto liveness pode levar à reinicialização. (Kubernetes Authors, 2026)

**Hubble** é a camada de observabilidade de fluxos do Cilium: ela apresenta eventos disponíveis conforme instrumentação, versão e configuração. Esses eventos não mostram, por si só, todo o payload nem todo o estado do datapath. (Cilium Authors, 2026)

Ao final, você poderá:

- relacionar Node, Pod, Deployment, Service, selector e EndpointSlice;
- apontar quando a rede do Pod, a resolução DNS e o encaminhamento do Service têm papéis diferentes;
- explicar o que as probes verificam e o que uma evidência de Hubble não mostra.

**Pré-requisitos:** vocabulário dos capítulos anteriores. O cenário usa apenas três Pods e dois Services internos; não instala componentes do cluster.

**Analogia limitada:** Deployment lembra uma receita de quantas cópias manter; Service lembra um endereço de atendimento. A receita não descreve cada pacote, e o endereço lógico não é uma pessoa nem contém a aplicação.

### 3.2 Criação de Pod e escolha de endpoint

O plano de controle recebe a intenção do Deployment. Um controlador mantém o conjunto de Pods; o scheduler escolhe um nó; o agente daquele nó e o CNI preparam a interface de rede do Pod. O Deployment não escolhe uma rota HTTP, o Service não inicia um contêiner e o CNI não substitui a aplicação. (Kubernetes Authors, 2026)

**Figura 3 – Deployment, Pod, Service e EndpointSlice respondem perguntas diferentes**

![Três quadros em ordem: 1 declara um Deployment api com uma réplica e label app=api; 2 mostra o controller mantendo o Pod desejado, que contém o contêiner e executa no Node, enquanto CNI prepara a rede; 3 mostra o Service selecionando labels e a EndpointSlice registrando destinos prontos. A faixa inferior percorre frontend, Service api na porta 80, Pod api NGINX na 8080, Service backend na 80 e Pod backend na 8080. IPs de Pod são dinâmicos.](diagramas/ebpf-cilium-iniciantes/figura-06-kubernetes-objetos.png)

Fonte: elaboração própria (2026), com base em (Kubernetes Authors, 2026) e no percurso E02.\
Nota: nomes são do laboratório, endereço de Pod e topologia permanecem dinâmicos.

```{=latex}
\FloatBarrier
```

O laboratório tem quatro papéis, mas três Deployments: frontend é um cliente curl ocioso; api é NGINX funcionando como proxy reverso; backend é BusyBox httpd servindo arquivos estáticos. “API” aqui nomeia um proxy didático, não uma API de negócio. O Service backend deve existir antes de o Deployment api iniciar: o NGINX usa o nome DNS backend em sua configuração. O Service api também recebe na porta 80 e aponta para o contêiner NGINX em 8080. (Kubernetes Authors, 2026) (NGINX Container Project, 2026)

A API tem uma rota local /ready que responde se o próprio processo NGINX está servindo. Ela não testa o backend. O backend fornece /health; a probe HTTP do Kubernetes consulta esse arquivo estático por httpd. O frontend executa sleep infinity e não é servidor; não recebe uma falsa probe HTTP que diga se a cadeia inteira está saudável. As sondagens HTTP devem ser interpretadas como uma verificação do endpoint especificado, não como teste da aplicação toda. (Kubernetes Authors, 2026)

Cada Pod usa usuário não root, seccomp RuntimeDefault, capabilities descartadas, sem escalada de privilégio, sistema de arquivos raiz somente leitura quando viável, recursos declarados e sem montagem de token de identidade do Kubernetes. O **ServiceAccount** é uma identidade atribuída a um Pod; a do exercício não recebe Role ou RoleBinding. Os contêineres NGINX e BusyBox usam volumes de configuração apenas para leitura; NGINX recebe /tmp gravável para PID e arquivos temporários exigidos por sua imagem sem abrir o resto do sistema de arquivos. A imagem NGINX unprivileged escuta em 8080. (Kubernetes Authors, 2026) (NGINX Container Project, 2026)

**Exemplo ilustrativo de encadeamento**

1. frontend consulta api dentro do mesmo namespace.
2. DNS localiza o Service api.
3. O Service encaminha a conexão à porta 8080 do Pod api.
4. O processo NGINX encaminha de verdade para http://backend:80.
5. Service backend escolhe Pod backend e encaminha para 8080.
6. BusyBox httpd devolve o arquivo; NGINX devolve corpo e cabeçalho X-Lab-Route.

Cada passo pode falhar por motivos diferentes. Status Ready do backend não prova que o Service o seleciona; um Service existente não prova que há EndpointSlice pronto; e um Pod com processo vivo não prova que a resposta da cadeia foi correta.

### 3.3 Vocabulário para ler o laboratório

Antes dos exercícios, separe palavras parecidas que apontam para coisas diferentes:

- **Namespace Kubernetes:** escopo lógico usado para agrupar muitos objetos namespaced. Não equivale a um namespace Linux nem isola sozinho todos os recursos do cluster.
- **YAML:** formato de texto para representar dados. Um arquivo pode conter um ou mais documentos YAML.
- **Manifesto:** declaração de um recurso Kubernetes. Aplicar um manifesto pede ao API server que aproxime o estado do cluster do estado declarado; não é uma receita universal de rede.
- **ServiceAccount:** identidade atribuída a um Pod dentro do cluster; não é a conta pessoal usada pelo aluno no terminal.
- **Porta do Service e targetPort:** o cliente usa a porta estável do Service; o Service encaminha ao número de porta indicado nos Pods. Neste laboratório, o mapeamento declarado é 80 para 8080.
- **Ingress na policy:** tráfego que chega ao Pod selecionado. Não confunda esse sentido de rede com um objeto Kubernetes Ingress, que não é usado neste recorte.
- **EndpointSlice:** parte da lista de destinos associados ao Service, com endereços e condições de prontidão.
- **Hubble Relay:** componente do instrutor para consultar eventos de fluxo; a saída não é captura completa nem audit log do API server. (Cilium Authors, 2026)

**Resumo C03:** o Deployment mantém Pods; o CNI prepara sua rede; labels e selectors relacionam objetos; o Service oferece um destino lógico; a EndpointSlice mostra destinos associados. Uma probe examina um endpoint indicado, e Hubble mostra apenas os campos de fluxo que a versão e a configuração disponibilizam.

**Perguntas para conferir**

1. Namespace Kubernetes e namespace Linux são a mesma coisa?
2. Qual objeto mantém o Pod desejado e qual objeto oferece o destino lógico ao cliente?
3. O que uma EndpointSlice acrescenta à leitura do Service?
4. Uma probe local ou um evento Hubble prova que toda a aplicação está saudável?

**Gabarito comentado:** (1) não; namespaces Linux e Kubernetes diferem. (2) Deployment mantém Pods; Service oferece destino lógico. (3) EndpointSlice registra destinos associados e prontidão. (4) não; uma probe ou um fluxo Hubble não prova a saúde da aplicação inteira.

**Atividade sem cluster — 8 minutos:** na Figura 3, use cores diferentes para indicar Deployment e Service e circule EndpointSlice. Trace frontend → api → backend; identifique qual objeto mantém o Pod, qual oferece o destino lógico e qual lista destinos associados.

**Resultado esperado — ILUSTRATIVO:** Deployment mantém Pods; Service nomeia e seleciona destinos; EndpointSlice os registra. A figura não comprova topologia nem estado observado do cluster.

**Erro comum:** tratar o namespace como fronteira completa de segurança ou o Service como um processo. São objetos e escopos distintos; leia cada um pelo papel que desempenha.

**Glossário consultável**

- **Cluster:** plano de controle e nós que executam Pods.
- **Deployment:** objeto que mantém o conjunto declarado de Pods.
- **Label / selector:** par chave-valor de um objeto / regra que seleciona objetos com o par.
- **Service:** nome e destino lógico para Pods selecionados.
- **CNI:** interface pela qual componentes de rede configuram a rede dos Pods.
- **Probe:** verificação periódica do endpoint configurado.
- **NetworkPolicy:** regra que seleciona Pods e descreve comunicações permitidas.
- **Hubble:** observabilidade de fluxos do Cilium.

**Leituras:** Pods, Deployments, Services, EndpointSlices, probes, NetworkPolicy e observabilidade do Hubble.

## Laboratório guiado

Os seis exercícios formam um percurso; cada etapa deixa uma evidência para a seguinte. Os laboratórios de revisão A, B e C organizam esses mesmos passos por resultados, sem criar outra rodada:

1. **E01 · Preparar e reconhecer:** conferir versão, identidade, reserva, memória e revisão; só então criar a namespace da rodada.
2. **E02 · Ver a cadeia saudável:** criar a API proxy e comparar o pedido pelo caminho completo com o acesso direto ao backend.
3. **E03 · Observar uma janela:** correlacionar poucos pedidos manuais com fluxos Hubble; Terminal B mantém apenas o port-forward.
4. **E04 · Testar a policy:** preservar o caminho positivo pela API e reunir evidência correlacionada para o acesso direto bloqueado.
5. **E05 · Diagnosticar e restaurar:** introduzir somente o selector defeituoso previsto, comparar as evidências e restaurar o Service.
6. **E06 · Registrar e limpar:** separar recibo local de audit log do API server e remover somente a namespace cuja identidade foi reconferida.

**Papéis**

- **Instrutor:** entrega revisão e manifests correspondentes, identidade explícita, dados das verificações prévias, reserva da VM/cluster e ajuda durante a sessão.
- **Aluno:** trabalha somente na namespace própria, mantém o recibo local, registra esperado e observado separadamente, interrompe diante de divergência e não amplia o alcance de uma correção.

**Terminais e lugares de execução**

- **Terminal A · VM Linux:** sessão persistente para os comandos do roteiro, variáveis, atalho k e recibo. Mantenha-o aberto de E01 até a limpeza em E06; não reconstrua uma identidade perdida por suposição.
- **Terminal B · VM Linux:** sessão temporária usada somente pelo processo de port-forward do E03. Não herda as variáveis de A; encerre o encaminhamento com Ctrl-C depois de E05 ou quando o instrutor pedir.
- **POD · execução remota:** quando a linha usa `kubectl exec ... --`, kubectl é chamado em A, mas o comando depois de `--` roda no contêiner indicado. Não cole esses comandos no host pessoal.

> **Condição para praticar.** O guia e os manifests são da mesma revisão de trabalho e não foram reproduzidos em cluster. Use somente o ambiente Linux que o instrutor reservou e liberou para a turma. Se uma condição ou identidade estiver desconhecida, pare antes de criar recursos; não instale nem altere Cilium, Hubble ou configuração do cluster.

### Como preparar o primeiro exercício

Os manifests acompanham o guia em poc-k8s-fabric/k8s/p010-iniciantes/. Obtenha o repositório ou pacote do instrutor e confira a revisão indicada; não misture arquivos de versões diferentes. Eles deixam o campo namespace ausente de propósito, e os comandos usam a namespace da rodada com -n. Os três Deployments usam uma réplica cada. Imagens são referenciadas por digest de índice conferido em recibo; isso não prova que o ambiente consiga baixá-las ou executá-las.

No Terminal A, os comandos kubectl, cilium e hubble rodam na VM Linux. O API server e os agentes Cilium ficam no cluster. Um comando termina com código de saída; curl também pode imprimir um status HTTP. Registre os dois sinais quando ambos existirem. Aspas duplas preservam variáveis como "$LAB_NS" como uma unidade; aspas simples preservam texto literal. Uma barra invertida no fim da linha continua o comando na linha seguinte.

No E03, abra Terminal B apenas para o port-forward do Relay, pois uma sessão Bash nova não herda as variáveis de A. No Terminal A, uma chamada kubectl exec começa no cliente e o processo após `--` roda no contêiner frontend. Ctrl-C encerra o processo em primeiro plano do terminal atual; use-o no B para parar o encaminhamento, nunca enquanto um comando estiver aplicando ou apagando recursos.

Os comandos centrais usam uma namespace nova por rodada. Se Terminal A for fechado, não reconstrua UID, run-id ou contexto por suposição; pare e peça ao instrutor para recuperar o recibo.

## Laboratório de revisão A: Comprovar a cadeia

Esta revisão reúne E01–E02 para confirmar a identidade e comparar, na mesma namespace e recibo, os caminhos pela API e direto ao backend.

> **Ficha A. Estado inicial: NOT_RUN**
>
> **Requisito:** identidade confirmada e dois caminhos HTTP comparados.
>
> **Evidência observada:** ainda não coletada.
>
> **Decisão:** pendente até conferir status, corpo, cabeçalho e destinos.

**Apoio visual:** Figuras 4 e 5. Cada desenho aparece no exercício correspondente, antes dos comandos.

**Estado de entrada:** o instrutor confirma reserva, revisão e condições; a namespace ainda não existe. Preparação e criação em E01 são obrigatoriamente assistidas e só ocorrem após as confirmações.

**Critérios de saída:** contexto, API server e UIDs conferem; ambas as rotas retornam HTTP 200 e o mesmo corpo; só a API traz o cabeçalho. Probes e EndpointSlice não provam a cadeia HTTP.

**Tarefas por resultado:**

1. **Identificar a rodada:** registre revisão, UTC, contexto, API server, UID de `kube-system` e run-id. Dado ausente ou incerto exige parada; o instrutor acompanha a criação só após confirmar as condições.
2. **Comprovar o caminho:** observe probes, Service e EndpointSlice; compare respostas pela API e diretas e registre status, corpo e código. Só a API deve incluir `X-Lab-Route: via-api-proxy`.

**Decisão diagnóstica:** se probe falhar ou faltar destino, compare labels, selector e EndpointSlice; Pod Ready confirma só a probe, e erro de curl não prova a causa.

**Apoio opcional:** E01.1–E01.8 e E02.1–E02.5 localizam orientações; preparação e criação em E01 continuam assistidas.

**Entregas e estado de saída:** use os campos existentes para esperado, observado e conclusão; mantenha namespace, Terminal A, variáveis e recibo para B. Não crie outro recibo, reexecute ou limpe.

## E01 — Reconhecer o ambiente e preparar a rodada

### Antes de começar

**Objetivo:** confirmar identidade explícita do cluster e da namespace, reserva, capacidade, estado inicial e revisão dos arquivos antes de criar recursos isolados.

**Pré-requisitos:** acesso à VM autorizado pelo instrutor; reserva exclusiva confirmada; revisão exata do guia e manifests; Cilium e Hubble Relay já configurados; modo de conexão e compatibilidade do cliente Hubble declarados pelo instrutor; policies globais e recursos protegidos avaliados pelo instrutor; pelo menos 4 GiB disponíveis em MemAvailable na VM. Se qualquer condição for desconhecida, pare antes da criação.

### Cenário e figura

**Figura 4 – E01 confere identidade e condições prévias antes de criar a namespace**

![Quatro etapas em sequência: 1 VM Linux autorizada e revisão conferida; 2 reserva, Cilium/Hubble, baseline e policies confirmadas; 3 contexto, API server, UIDs, versão e memória conferem; 4 namespace com run-id ainda não existe. Uma seta SIM liga 3 a 4 e outra SIM liga 4 a CREATE, que guarda UID e run-id. A caixa vermelha abaixo é um aviso geral separado: pare e chame o instrutor se qualquer item for desconhecido.](diagramas/ebpf-cilium-iniciantes/figura-07-e01-gates.png)

Fonte: elaboração própria (2026), com base em (Kubernetes Authors, 2026) e no processo de admissão definido para este laboratório.
Nota: as condições são verificações prévias; a figura não registra nem certifica um ambiente executado.

```{=latex}
\FloatBarrier
```

### Preveja antes de executar

Antes de continuar, anote: que evidência distingue um cluster autorizado de um contexto apenas parecido? E qual dado ainda precisa vir do instrutor antes de criar a namespace?

**Registre sua previsão antes dos comandos:**

```{=latex}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}
```

### Passos

**Fase 1 — Confira os arquivos e identifique o ambiente**

**E01.1 · Instrutor e aluno — Confirme as condições prévias**

Confirme com o instrutor a reserva exclusiva, as condições de Cilium/Hubble, as policies globais, a linha de base protegida e a capacidade. A reserva evita que outra turma altere os mesmos objetos durante E04 e E05. Não use comandos de uma turma anterior como atalho.

**E01.2 · Terminal A · VM Linux — Confira os arquivos da revisão**

Entre na cópia fornecida e confira que os manifests são da mesma revisão indicada pelo instrutor. O primeiro comando mostra o diretório atual; o segundo lista os YAML; o terceiro calcula uma soma por arquivo, sem ler credenciais:

~~~bash
pwd
find poc-k8s-fabric/k8s/p010-iniciantes -maxdepth 1 -type f -print
sha256sum poc-k8s-fabric/k8s/p010-iniciantes/*.yaml
~~~

**E01.3 · Terminal A · VM Linux — Preencha a identidade da sessão**

Copie os valores de identidade fornecidos pelo instrutor para a sessão Bash. O caminho do kubeconfig deve ser absoluto. O arquivo contém credenciais e nunca deve ser impresso, anexado ao recibo ou copiado para os Pods. Escolha um nome novo para a rodada, usando somente letras minúsculas, dígitos e hífens na namespace; substitua os exemplos por valores reais:

~~~bash
export LAB_KUBECONFIG='/caminho/absoluto/fornecido/pelo/instrutor'
export LAB_CONTEXT='contexto-fornecido-pelo-instrutor'
export LAB_API_SERVER='https://api-fornecida-pelo-instrutor:6443'
export LAB_CLUSTER_UID='uid-kube-system-fornecido-pelo-instrutor'
export LAB_CILIUM_NS='namespace-cilium-fornecido-pelo-instrutor'
export LAB_NS='p010-aluno-20261028-a1b2'
export LAB_RUN_ID='20261028-a1b2'
export LAB_GUIDE_REVISION='revisao-fornecida-pelo-instrutor'
export LAB_DIR="$PWD/poc-k8s-fabric/k8s/p010-iniciantes"
export LAB_GUIDE="$PWD/poc-k8s-fabric/docs/ebpf-cilium-iniciantes.md"
LAB_DIR_REL='poc-k8s-fabric/k8s/p010-iniciantes'
LAB_GUIDE_REL='poc-k8s-fabric/docs/ebpf-cilium-iniciantes.md'
~~~

**Fase 2 — Prepare Terminal A e o recibo local**

```{=latex}
\markboth{E01.4 · Terminal A · Preparação assistida}{E01.4 · Terminal A · Preparação assistida}
```

**E01.4 · Terminal A · VM Linux — Defina os atalhos e prepare o recibo**

Esta é a preparação única obrigatória do roteiro. Execute-a uma vez com o instrutor no Terminal A, antes da primeira chamada à API. Você não precisa dominar Bash avançado: copie o bloco inteiro, na ordem, e peça ao instrutor para orientar a colagem. Ele usa os valores de identidade e caminhos preenchidos em E01.3. O atalho k reaproveita kubeconfig e contexto nas chamadas kubectl; record guarda a saída e o código de retorno no recibo local privado. Ao final, o recibo deve existir e k e record devem estar disponíveis na mesma sessão A. Se algo falhar ou não estiver claro, pare e chame o instrutor:

~~~bash
for name in \
  LAB_KUBECONFIG LAB_CONTEXT LAB_API_SERVER LAB_CLUSTER_UID \
  LAB_CILIUM_NS LAB_NS LAB_RUN_ID LAB_GUIDE_REVISION LAB_DIR \
  LAB_GUIDE LAB_DIR_REL LAB_GUIDE_REL; do
  if [[ -z "${!name:-}" ]]; then
    printf 'Falta preencher %s; pare e peça ao instrutor.\n' \
      "$name" >&2
    exit 1
  fi
done
if [[ "$LAB_KUBECONFIG" != /* ]]; then
  printf 'LAB_KUBECONFIG deve ser um caminho absoluto.\n' >&2
  exit 1
fi
if [[ ! "$LAB_GUIDE_REVISION" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  printf 'Revisão do guia deve ser tag ou commit sem espaços.\n' >&2
  exit 1
fi
if [[ ! "$LAB_NS" =~ ^p010-[a-z0-9]([-a-z0-9]{0,56}[a-z0-9])?$ ||
      ! "$LAB_RUN_ID" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]; then
  printf 'LAB_NS ou LAB_RUN_ID não atende ao formato combinado.\n' \
    >&2
  exit 1
fi
if [[ ! -r "$LAB_KUBECONFIG" || ! -d "$LAB_DIR" ||
      ! -r "$LAB_GUIDE" || ! -d "$LAB_DIR_REL" ||
      ! -r "$LAB_GUIDE_REL" ]]; then
  printf 'Kubeconfig, guia ou diretório não está acessível.\n' \
    >&2
  exit 1
fi
k() {
  kubectl --kubeconfig "$LAB_KUBECONFIG" \
    --context "$LAB_CONTEXT" "$@"
}
umask 077
LAB_RECEIPT_DIR="$HOME/lab-receipts/$LAB_RUN_ID"
if [[ -e "$LAB_RECEIPT_DIR" ]]; then
  printf 'Recibo existente; escolha outro run-id com o instrutor.\n' \
    >&2
  exit 1
fi
mkdir -m 700 -p "$LAB_RECEIPT_DIR" || exit 1
LAB_RECEIPT="$LAB_RECEIPT_DIR/receipt.md"
cat > "$LAB_RECEIPT" <<EOF || exit 1
# Recibo local do laboratório

Revisão do guia: $LAB_GUIDE_REVISION
Início UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)
VM Linux: $(uname -srm)
Contexto esperado: $LAB_CONTEXT
API server esperado: $LAB_API_SERVER
UID kube-system esperado: $LAB_CLUSTER_UID
Namespace/run-id: $LAB_NS / $LAB_RUN_ID
Modo Hubble: preencher após declaração do instrutor

Não incluir kubeconfig, token, certificado, chave, Secret ou dado
pessoal. Resultados vazios são NOT_RUN, nunca suposições.

E01 — gates, versão, memória e criação
Esperado:
Observado:
Códigos de saída:
UID namespace criado:

E02 — cadeia e probes locais
Esperado:
Observado:
Códigos de saída:

E03 — janela Hubble e modo de conexão declarado
Esperado:
Observado:
Códigos de saída:

E04 — policy e contraprovas
Esperado:
Observado:
Códigos de saída:

E05 — selector e restauração
Esperado:
Observado:
Códigos de saída:

E06 — hashes, versões, imageID, arquitetura e cleanup
Esperado:
Observado:
Códigos de saída:
ImageIDs e arquitetura: preencher somente após execução admitida
Resultado do cleanup:
EOF
if [[ ! -f "$LAB_RECEIPT" ]]; then
  printf 'Recibo local ausente; pare antes de consultar o cluster.\n' \
    >&2
  exit 1
fi
record() {
  local label="$1"
  local command_rc
  local -a header_status
  local -a output_status
  local -a result_status
  shift
  RECORD_LOG_FAILED=0
  RECORD_COMMAND_RC=0
  if [[ -z "${LAB_GUIDE_REVISION:-}" ||
        -z "${RECORD_STEP:-}" ]]; then
    RECORD_LOG_FAILED=1
    printf 'Falta revisão ou passo para identificar o comando.\n' >&2
    return 125
  fi
  printf '\n## guia=%s | passo=%s | %s\n' \
    "$LAB_GUIDE_REVISION" "$RECORD_STEP" "$label" \
    | tee -a "$LAB_RECEIPT"
  header_status=("${PIPESTATUS[@]}")
  if (( header_status[0] != 0 || header_status[1] != 0 )); then
    RECORD_LOG_FAILED=1
    return 125
  fi
  "$@" 2>&1 | redact_receipt_output | tee -a "$LAB_RECEIPT"
  output_status=("${PIPESTATUS[@]}")
  command_rc=${output_status[0]}
  RECORD_COMMAND_RC="$command_rc"
  if (( output_status[1] != 0 || output_status[2] != 0 )); then
    RECORD_LOG_FAILED=1
    return 125
  fi
  printf 'exit_code=%s\n' "$command_rc" | tee -a "$LAB_RECEIPT"
  result_status=("${PIPESTATUS[@]}")
  if (( result_status[0] != 0 || result_status[1] != 0 )); then
    RECORD_LOG_FAILED=1
    return 125
  fi
  return "$command_rc"
}
redact_receipt_output() {
  local line
  local path
  while IFS= read -r line || [[ -n "$line" ]]; do
    for path in \
      "${LAB_KUBECONFIG:-}" \
      "${HUBBLE_TLS_CA_CERT_FILES:-}" \
      "${HUBBLE_TLS_CLIENT_CERT_FILE:-}" \
      "${HUBBLE_TLS_CLIENT_KEY_FILE:-}"; do
      if [[ -n "$path" ]]; then
        line=${line//"$path"/'[caminho local omitido]'}
      fi
    done
    printf '%s\n' "$line"
  done
}
~~~

```{=latex}
\markboth{E01 — Reconhecer o ambiente e preparar a rodada}{E01 — Reconhecer o ambiente e preparar a rodada}
```

**Fase 3 — Confira identidade, capacidade e estado inicial**

**E01.5 · Terminal A · VM Linux — Confira cliente, servidor e identidade**

Compare a versão do cliente e do servidor, o contexto selecionado por `--context`, o endpoint e o UID da namespace kube-system com o registro recebido. O UID de kube-system é uma impressão de identidade fornecida pelo instrutor, não um nome global padronizado para cluster. Salve a versão no recibo e encerre em qualquer erro:

~~~bash
RECORD_STEP='E01.5'
record 'kubectl version' k version || exit 1
actual_context="$(k config view --minify \
  -o jsonpath='{.contexts[0].name}')" || exit 1
actual_server="$(k config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}')" || exit 1
actual_cluster_uid="$(k get namespace kube-system \
  -o jsonpath='{.metadata.uid}')" || exit 1
printf 'Contexto observado: %s\nAPI server observado: %s\n' \
  "$actual_context" "$actual_server" \
  | tee -a "$LAB_RECEIPT" || exit 1
printf 'UID kube-system observado: %s\n' \
  "$actual_cluster_uid" \
  | tee -a "$LAB_RECEIPT" || exit 1
if [[ "$actual_context" != "$LAB_CONTEXT" ||
      "$actual_server" != "$LAB_API_SERVER" ||
      "$actual_cluster_uid" != "$LAB_CLUSTER_UID" ]]; then
  printf 'Identidade divergente; pare e chame o instrutor.\n' \
    >&2
  printf 'Identidade divergente; criação não autorizada.\n' \
    >> "$LAB_RECEIPT"
  exit 1
fi
  printf 'Contexto, API server e UID conferidos.\n' \
  | tee -a "$LAB_RECEIPT" || exit 1
~~~

**E01.6 · Terminal A · VM Linux — Confira memória e namespace ausente**

Verifique a capacidade da VM, usando o valor MemAvailable do Linux. O operador || exit 1 faz o shell realmente parar se awk não encontrar memória suficiente. Depois confira que o nome novo não aparece na lista. Uma falha de conexão também interrompe; não a interprete como namespace ausente:

~~~bash
RECORD_STEP='E01.6'
record 'MemAvailable' awk '
  /^MemAvailable:/ {
    print $2 " KiB disponíveis"
    if ($2 < 4194304) exit 1
    found = 1
  }
  END { if (!found) exit 1 }
' /proc/meminfo || exit 1
existing_namespaces="$(k get namespaces \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" \
  || exit 1
if printf '%s\n' "$existing_namespaces" | grep -Fxq -- "$LAB_NS"; then
  printf 'Namespace já existe; não a adote. Escolha outro run-id.\n' \
    >&2
  printf 'Namespace pré-existente; criação não tentada.\n' \
    >> "$LAB_RECEIPT"
  exit 1
fi
printf 'Namespace ausente antes da criação.\n' \
  | tee -a "$LAB_RECEIPT" || exit 1
~~~

```{=latex}
\clearpage
```

**Fase 4 — Registre a confirmação e crie a namespace**

**E01.7 · Terminal A · VM Linux — Registre confirmação e hashes**

Peça ao instrutor a confirmação efetiva da reserva exclusiva, da capacidade, de Cilium/Hubble, da baseline protegida e das policies globais. A baseline pode viver em outro contexto: não consulte nem altere esse contexto com a identidade desta prática. No recibo local, preencha com o instrutor a confirmação recebida, a revisão consultada e a hora UTC. A frase impressa pelo comando é um marcador incompleto; não confirma as condições nem substitui os dados efetivos. Se faltar confirmação, revisão ou hora UTC, pare e não avance para E01.8. Registre também os hashes dos arquivos:

~~~bash
RECORD_STEP='E01.7'
printf 'Confirmação, revisão e UTC: preencher com o instrutor.\n' \
  | tee -a "$LAB_RECEIPT" || exit 1
record 'hashes do guia e manifests' \
  sha256sum "$LAB_GUIDE_REL" "$LAB_DIR_REL"/*.yaml || exit 1
~~~

**E01.8 · Terminal A · VM Linux — Crie a namespace somente após a confirmação**

Somente depois de todas as condições prévias confirmadas, crie a namespace com um documento YAML enviado pela entrada padrão. create -f cria apenas um objeto novo; o servidor devolve o UID na mesma resposta. Se já existir ou a criação falhar, o comando retorna erro e exit 1 interrompe o shell; não tente apply nem outro contexto:

~~~bash
create_label='kubectl create -f - -o jsonpath={.metadata.uid}'
printf '\n## guia=%s | passo=E01.8 | %s\n' \
  "$LAB_GUIDE_REVISION" "$create_label" \
  | tee -a "$LAB_RECEIPT"
create_header_status=("${PIPESTATUS[@]}")
if (( create_header_status[0] != 0 ||
      create_header_status[1] != 0 )); then
  printf 'Recibo não confirmou criação; namespace não criada.\n' \
    >&2
  exit 1
fi
if LAB_NS_UID="$(k create -f - \
  -o jsonpath='{.metadata.uid}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${LAB_NS}
  labels:
    lab.learn-cilium.org/run-id: "${LAB_RUN_ID}"
EOF
)"; then
  :
else
  create_rc=$?
  printf 'Namespace create falhou; exit_code=%s. Pare.\n' \
    "$create_rc" | tee -a "$LAB_RECEIPT" || exit 1
  exit "$create_rc"
fi
if [[ -z "$LAB_NS_UID" ]]; then
  printf 'A criação não devolveu UID; pare e chame o instrutor.\n' \
    >&2
  exit 1
fi
printf 'namespace=%s uid=%s run-id=%s exit_code=0\n' \
  "$LAB_NS" "$LAB_NS_UID" "$LAB_RUN_ID" \
  | tee -a "$LAB_RECEIPT" || exit 1
~~~

Os valores LAB_NS e LAB_RUN_ID foram limitados a caracteres seguros no passo 4 para que o shell os possa inserir no YAML. Registre a revisão, UTC e UID retornado. O recibo foi criado antes da primeira chamada ao API server e permanece local com permissão restrita.

### Confira e registre

**Esperado — ILUSTRATIVO:** versão de cliente/servidor e identidade conferem; capacidade atende o limite definido para a VM; namespace ainda não existe; o instrutor confirma a linha de base e as policies; a namespace criada tem UID próprio e label de run-id. Nenhum desses resultados foi coletado neste documento.

**Observado — NOT_RUN (ainda não executado)**

- Revisão do guia e hashes: \hrulefill
- Hora UTC e versão da VM: \hrulefill
- Contexto, API server e UID kube-system: \hrulefill
- MemAvailable observado: \hrulefill
- Confirmação das condições prévias pelo instrutor: \hrulefill
- Namespace, run-id e UID criados: \hrulefill
- Código de saída de cada etapa: \hrulefill
- Diagnóstico ou condição ainda não confirmada: \hrulefill

### Interprete

Uma identidade consistente reduz o risco de atuar no cluster errado; a reserva e a avaliação de policies reduzem interferência; uma namespace nova delimita objetos namespaced. Esses sinais não provam ausência de toda política externa nem substituem a confirmação do instrutor.

### Se falhar

Qualquer divergência de contexto, API server, UID, memória, versão, namespace existente, condição desconhecida ou erro de conexão encerra E01 sem criar recursos. Mantenha o recibo do erro e chame o instrutor. Não tente trocar para um contexto padrão, completar uma instalação ou reutilizar uma namespace.

### Critério para seguir

As condições prévias foram confirmadas; a identidade explícita conferiu; a namespace não existia antes e foi criada com run-id; UID e hashes ficaram registrados sem material secreto.

### Gabarito para conferir depois

A checagem de endpoint e UID responde “qual cluster”; o nome da namespace com run-id responde “qual rodada”; a reserva responde “quem mais pode estar mudando o ambiente”; e a linha de base/policies respondem “o que não deve ser quebrado”. Uma namespace ajuda a limitar nomes, mas não isola todo recurso nem controla políticas globais.

### Próxima etapa

Terminal A conserva contexto, namespace, run-id, UID e recibo. Prossiga em E02 na mesma rodada; a conferência do laboratório A termina depois de comparar os dois pedidos. Não crie outra namespace nem limpe a atual.

## E02 — Acompanhar uma requisição saudável

### Antes de começar

**Objetivo:** criar a cadeia frontend → Service api → NGINX proxy → Service backend → BusyBox httpd e comparar a resposta pela API com o acesso direto ao backend.

**Pré-requisitos:** E01 concluído, namespace e UID preservados, mesma revisão do guia/manifests, imagens aprovadas e disponibilidade verificada pelo instrutor. O Service backend deve existir antes de o processo NGINX da API iniciar, pois a configuração do proxy usa o nome DNS backend.

### Cenário e figura

O frontend é cliente; o Pod api executa o proxy; o backend serve a página. O mesmo frontend também pode chamar o Service backend diretamente, caminho que deixa de ser permitido em E04.

**Figura 5 – E02 compara o caminho pelo proxy com o acesso direto**

![Caminho A percorre frontend, Service api, Pod NGINX, Service backend e Pod BusyBox; uma frase abaixo do caminho informa que a resposta retorna pela mesma cadeia, e uma caixa mostra X-Lab-Route: via-api-proxy. Caminho B liga frontend, Service backend e Pod BusyBox; uma seta tracejada volta ao frontend com o rótulo resposta direta. A resposta direta não inclui o header X-Lab-Route.](diagramas/ebpf-cilium-iniciantes/figura-08-e02-caminho.png)

Fonte: elaboração própria (2026), com base em (Kubernetes Authors, 2026), (BusyBox Authors, 2026) e (NGINX Container Project, 2026).
Nota: objetos e portas vêm dos manifests; endereços e tráfego não foram observados.

```{=latex}
\FloatBarrier
```

### Preveja antes de executar

Desenhe duas linhas: frontend → api → backend e frontend → backend. Qual delas passa pelo proxy e qual deve incluir o cabeçalho X-Lab-Route? Escreva também o status HTTP esperado antes de aplicar a policy.

**Registre sua previsão antes dos comandos:**

```{=latex}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}
```

### Passos

**E02.1 · Terminal A · VM Linux — Confira a revisão dos manifests**

Confira que os hashes dos YAML correspondem à revisão confirmada pelo instrutor. Hash identifica bytes daquele arquivo, não confirma que foi aplicado ou baixado no cluster:

~~~bash
RECORD_STEP='E02.1'
record 'E02 hashes dos manifests' \
  sha256sum "$LAB_DIR_REL"/*.yaml || exit 1
~~~

**E02.2 · Terminal A · VM Linux — Prepare configuração e ServiceAccount**

Crie a ServiceAccount sem permissões adicionais e as ConfigMaps. Elas guardam a página de resposta, health check e configuração do NGINX. O token automático fica desabilitado no manifesto:

~~~bash
RECORD_STEP='E02.2'
record 'E02 aplicar ConfigMaps e ServiceAccount' \
  k apply -n "$LAB_NS" -f "$LAB_DIR/00-config.yaml" \
  || exit 1
record 'E02 ServiceAccount' \
  k -n "$LAB_NS" get serviceaccount lab-workload || exit 1
record 'E02 ConfigMaps' \
  k -n "$LAB_NS" get configmaps || exit 1
~~~

```{=latex}
\clearpage
```

**E02.3 · Terminal A · VM Linux — Crie o backend antes do proxy**

Crie primeiro o Service backend e depois o Deployment. O Service fornece o nome DNS backend; o Pod BusyBox serve / e /health na porta 8080. Aguarde a probe /health:

~~~bash
RECORD_STEP='E02.3'
record 'E02 criar Service backend antes do NGINX' \
  k apply -n "$LAB_NS" \
  -f "$LAB_DIR/10-backend-service.yaml" || exit 1
record 'E02 criar Deployment backend' \
  k apply -n "$LAB_NS" \
  -f "$LAB_DIR/11-backend-deployment.yaml" || exit 1
record 'E02 aguardar probe backend' \
  k -n "$LAB_NS" rollout status deployment/backend \
  --timeout=90s || exit 1
record 'E02 Service backend' \
  k -n "$LAB_NS" get service backend || exit 1
record 'E02 EndpointSlice backend' \
  k -n "$LAB_NS" get endpointslice \
  -l kubernetes.io/service-name=backend || exit 1
~~~

**E02.4 · Terminal A · VM Linux — Crie o Service e proxy da API**

Depois de confirmar o Service backend e seu estado, crie o Service api e o Deployment NGINX. A ordem garante que o nome backend existe quando NGINX carrega sua configuração. Aguarde a probe local /ready:

~~~bash
RECORD_STEP='E02.4'
record 'E02 criar Service api' \
  k apply -n "$LAB_NS" -f "$LAB_DIR/20-api-service.yaml" \
  || exit 1
record 'E02 criar Deployment api' \
  k apply -n "$LAB_NS" -f "$LAB_DIR/21-api-deployment.yaml" \
  || exit 1
record 'E02 aguardar probe local da API' \
  k -n "$LAB_NS" rollout status deployment/api \
  --timeout=90s || exit 1
~~~

```{=latex}
\clearpage
```

**E02.5 · Terminal A · VM Linux e POD via exec — Inicie o cliente e faça dois pedidos**

Inicie o cliente ocioso frontend por último. Ele executa sleep infinity, não serve HTTP e não gera tráfego sozinho. Faça somente as duas chamadas manuais abaixo; o comando executa curl dentro do contêiner por causa do texto depois de --:

~~~bash
RECORD_STEP='E02.5'
record 'E02 criar Deployment frontend' \
  k apply -n "$LAB_NS" -f "$LAB_DIR/30-frontend-deployment.yaml" \
  || exit 1
record 'E02 aguardar frontend ocioso' \
  k -n "$LAB_NS" rollout status deployment/frontend \
  --timeout=90s || exit 1
record 'E02 UTC antes do pedido API' \
  date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
if record 'E02 curl via API' \
  k exec -n "$LAB_NS" deploy/frontend -- \
  curl --fail-with-body -sS --connect-timeout 3 \
    --max-time 5 -D - http://api/; then
  rc_api=0
else
  rc_api=$?
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes do próximo pedido.\n' >&2
    exit 1
  fi
fi
printf 'E02 curl via API rc=%s\n' "$rc_api" \
  | tee -a "$LAB_RECEIPT" || exit 1
record 'E02 UTC antes do pedido direto' \
  date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
if record 'E02 curl direto ao backend' \
  k exec -n "$LAB_NS" deploy/frontend -- \
  curl --fail-with-body -sS --connect-timeout 3 \
    --max-time 5 -D - http://backend/; then
  rc_direct=0
else
  rc_direct=$?
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes do próximo pedido.\n' >&2
    exit 1
  fi
fi
printf 'E02 curl direto rc=%s\n' "$rc_direct" \
  | tee -a "$LAB_RECEIPT" || exit 1
~~~

Leia os cabeçalhos HTTP e o corpo na saída salva no recibo. `--fail-with-body` mantém o corpo de erro e faz curl devolver código diferente de zero em resposta HTTP de erro. record exibe e anota o código de cada comando; rc_api e rc_direct guardam os códigos de cada pedido separadamente. curl sem `--fail` pode retornar zero mesmo ao receber HTTP 502.

### Confira e registre

**Esperado — ILUSTRATIVO:** o primeiro pedido deve exibir HTTP 200, mensagem curta do backend e cabeçalho X-Lab-Route: via-api-proxy; o segundo deve exibir HTTP 200 e a mesma mensagem, sem esse cabeçalho. A imagem, DNS e ambiente reais podem divergir; nenhuma saída foi coletada neste guia.

**Observado — NOT_RUN (ainda não executado)**

- UTC e revisão/hash dos manifests: \hrulefill
- Versão cliente/servidor: \hrulefill
- Pod backend e probe /health: \hrulefill
- Service e EndpointSlice backend: \hrulefill
- Pod api e probe /ready: \hrulefill
- Resposta pela API — status, cabeçalho, corpo e código: \hrulefill
- Resposta direta — status, corpo e código: \hrulefill
- Diagnóstico apoiado pelos resultados: \hrulefill

### Interprete

A diferença de cabeçalho identifica o trecho que passou pelo proxy; a resposta direta mostra que o frontend alcança o Service backend antes da policy. Um Pod Ready comprova apenas sua probe local. Uma resposta ponta a ponta reúne mais evidências do que uma lista de Pods, mas ainda não testa policy ou Hubble.

### Se falhar

Se a probe backend falhar, confira ConfigMap, volume, porta e eventos do Pod antes de avançar. Se backend estiver pronto mas o EndpointSlice estiver vazio, compare labels e selector. Se a API não ficar Ready, confirme que o Service backend existia antes do NGINX e examine logs da API. Se o comando curl retornar HTTP 502, registre cabeçalho, código curl e horário; não atribua causa sem evidência. Não execute curl no contêiner NGINX nem reinicie recursos protegidos.

### Critério para seguir

Os dois pedidos retornam HTTP 200 e o conteúdo do backend; apenas a resposta pela API inclui o cabeçalho do proxy; os Pods API e backend passam probes locais; Service backend precedeu a inicialização do NGINX.

### Gabarito para conferir depois

O frontend é cliente, não servidor. DNS localiza um Service, o Service seleciona destinos e NGINX abre um segundo trecho HTTP para backend. O header X-Lab-Route é adicionado pela configuração da API, logo a chamada direta não o contém. Probes não verificam a cadeia inteira.

### Próxima etapa

Ao concluir E02, mantenha a namespace, Terminal A, variáveis e recibo; confira a ficha A com os dois resultados esperados. O laboratório B reúne os requisitos de E03 e E04 antes dos passos guiados. É a continuação da mesma rodada, sem recriar a cadeia.

## Laboratório de revisão B: Observar e restringir

Esta revisão relaciona pedidos a fluxos e compara a rota pela API à contraprova direta no ambiente já admitido.

> **Ficha B. Estado inicial: NOT_RUN**
>
> **Requisito:** Hubble no modo declarado; duas rotas correlacionadas.
>
> **Evidência observada:** ainda não coletada.
>
> **Decisão:** pendente por UTC, origem/destino e verdict.

**Apoio visual:** Figuras 6 e 7. Cada desenho aparece no exercício correspondente, antes dos comandos.

**Estado de entrada:** E02 e A usam a mesma namespace, Terminal A e recibo. O instrutor confirmou Relay, modo, versões, reserva e baseline. Não habilite nem altere Cilium.

**Critérios de saída:** Hubble no modo confirmado; UTC/filtro/identidades registrados; API 200 com cabeçalho; tentativa direta sem resposta, correlacionada ao backend/verdict. L7 ausente é neutro se desativado; timeout sem correlação é inconclusivo.

**Tarefas por resultado:**

1. **Estabelecer a observação:** com o instrutor, conecte no modo declarado e mantenha o port-forward próprio; sem fallback.
2. **Correlacionar:** registre UTC, filtro, namespace, origem/destino, protocolo, verdict e campos ausentes.
3. **Comparar:** preserve a API positiva e a contraprova direta; explique a diferença pelo evento recente do backend.

**Apoio opcional:** E03.1–E03.6/E04.1–E04.5. Conexão e port-forward são assistidos.

**Entregas e decisão diagnóstica:** anote versões CLI/Relay, modo sem segredo, janela, fluxos e HTTP no mesmo recibo. Diferencie saída de fluxo ausente; falha do Relay/timeout não prova bloqueio. Sem correlação, marque inconclusivo; não altere recursos nem policies.

**Saída para C:** mantenha policies, namespace, Terminal A, recibo e port-forward.

## E03 — Observar uma janela curta com Hubble

### Antes de começar

**Objetivo:** correlacionar alguns fluxos recentes com a namespace do laboratório e distinguir telemetria de fluxo de uma captura completa ou do audit log do API server.

**Pré-requisitos:** E02 concluído; Hubble Relay já disponível; versões CLI/Relay compatíveis e modo explicitamente declarado pelo instrutor: TLS verificado ou plaintext somente pelo port-forward configurado para loopback. Para TLS, obtenha CA, nome do servidor e eventual certificado cliente por canal seguro. Para plaintext, o instrutor confirma que o Relay o aceita e que o encaminhamento está preso a 127.0.0.1:4245. Não habilite Hubble, não instale charts, não altere o Relay e nunca ignore validação de certificado.

### Cenário e figura

Terminal A anota horário e gera pedidos. Terminal B mantém somente o port-forward temporário. A consulta mostra os eventos disponibilizados pelo Hubble, não o conteúdo integral dos pacotes.

**Figura 6 – E03 limita a observação ao namespace e à janela do exercício**

![Linha do tempo com T0 UTC, T+request e T+2 min. Terminal A anota UTC, faz dois pedidos manuais e consulta Hubble; terminal B mantém o port-forward ao Relay no modo TLS verificado ou plaintext loopback autorizado, e Ctrl-C é indicado somente nessa janela. A faixa inferior reúne UTC e namespace, origem e destino, protocolo e verdict; um aviso registra que payload completo e audit log do API server não são mostrados.](diagramas/ebpf-cilium-iniciantes/figura-09-e03-hubble.png)

Fonte: elaboração própria (2026), com base em (Cilium Authors, 2026), incluindo setup e configuração TLS do Relay.
Nota: Hubble é telemetria de fluxo; campos e retenção dependem da versão e configuração instaladas. Abra primeiro o port-forward no Terminal B; as caixas da figura indicam papéis, não a ordem de preparação dos terminais.

```{=latex}
\FloatBarrier
```

### Preveja antes de executar

Se a consulta Hubble não mostrar um pedido, que explicações existem além de “não houve tráfego”? Anote duas hipóteses e que campo ajudaria a distingui-las.

**Registre sua previsão antes dos comandos:**

```{=latex}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}
```

~~~{=latex}
\clearpage
~~~

### Passos

**E03.1 · Terminal B · VM Linux — Prepare a conexão temporária**

Mantenha o terminal A aberto. O terminal B é uma nova sessão Bash e não herda exports do terminal A. Copie para B o caminho absoluto do kubeconfig, o contexto e a namespace Cilium fornecidos pelo instrutor; não copie o conteúdo do kubeconfig:

~~~bash
export LAB_KUBECONFIG='/caminho/absoluto/fornecido/pelo/instrutor'
export LAB_CONTEXT='contexto-fornecido-pelo-instrutor'
export LAB_CILIUM_NS='namespace-cilium-fornecido-pelo-instrutor'
if [[ ! -r "$LAB_KUBECONFIG" || -z "$LAB_CONTEXT" ||
      -z "$LAB_CILIUM_NS" ]]; then
  printf 'Falta dado de conexão validado pelo instrutor; pare.\n' >&2
  exit 1
fi
~~~

**E03.2 · Terminal B · VM Linux — Inicie apenas o port-forward**

Inicie no terminal B somente o port-forward ao Relay já disponível. Confirme que o bind local usa loopback e que não escuta em interfaces externas; se não puder confirmar, pare. A conexão do cliente será configurada conforme o modo declarado. Não instale nem ative componentes:

~~~bash
cilium hubble port-forward \
  --kubeconfig "$LAB_KUBECONFIG" \
  --context "$LAB_CONTEXT" \
  -n "$LAB_CILIUM_NS"
~~~

**E03.3 · Terminal B · VM Linux — Mantenha o encaminhamento em primeiro plano**

Deixe o processo em primeiro plano no terminal B. A saída deve anunciar `127.0.0.1:4245`; confirme que não escuta em interfaces externas. Se o endereço estiver diferente ou incerto, pare. Mantenha o encaminhamento aberto até concluir E05.

```{=latex}
\clearpage
```

**E03.3a · Terminal A · VM Linux — Declare o modo informado**

No terminal A, declare o servidor local e o modo de conexão que o instrutor confirmou. Não tente TLS e depois plaintext automaticamente:

~~~bash
RECORD_STEP='E03.3'
export HUBBLE_SERVER='127.0.0.1:4245'
export HUBBLE_MODE='verified-tls'
~~~

**E03.3b · Terminal A · VM Linux — Monte os argumentos do modo declarado**

Substitua cada valor de exemplo pelos parâmetros declarados pelo instrutor antes de executar o próximo bloco. No modo `verified-tls`, defina CA, nome do servidor e `HUBBLE_REQUIRES_CLIENT_CERT` como `yes` ou `no` conforme a exigência do Relay. Se for `yes`, defina também os caminhos locais do certificado e da chave cliente; não os copie para o recibo. No modo `loopback-plaintext`, não defina flags TLS. Essa opção só vale para a conexão do port-forward em loopback, com autorização explícita do instrutor. Um erro nunca muda o modo:

~~~bash
RECORD_STEP='E03.3'
HUBBLE_CONNECTION_ARGS=()
case "$HUBBLE_MODE" in
  verified-tls)
    export HUBBLE_TLS_CA_CERT_FILES=\
      '/caminho/absoluto/da/CA-fornecida.crt'
    export HUBBLE_TLS_SERVER_NAME=\
      'nome-do-certificado-fornecido-pelo-instrutor'
    export HUBBLE_REQUIRES_CLIENT_CERT='no'
    if [[ ! -r "$HUBBLE_TLS_CA_CERT_FILES" ||
          -z "$HUBBLE_TLS_SERVER_NAME" ]]; then
      printf 'Parâmetros TLS incompletos; pare e chame o instrutor.\n' \
        >&2
      exit 1
    fi
    HUBBLE_CONNECTION_ARGS=(
      --tls
      --tls-ca-cert-files "$HUBBLE_TLS_CA_CERT_FILES"
      --tls-server-name "$HUBBLE_TLS_SERVER_NAME"
    )
    case "$HUBBLE_REQUIRES_CLIENT_CERT" in
      no) ;;
      yes)
        if [[ ! -r "${HUBBLE_TLS_CLIENT_CERT_FILE:-}" ||
              ! -r "${HUBBLE_TLS_CLIENT_KEY_FILE:-}" ]]; then
          printf 'Certificado cliente ausente; pare.\n' \
            >&2
          exit 1
        fi
        HUBBLE_CONNECTION_ARGS+=(
          --tls-client-cert-file "$HUBBLE_TLS_CLIENT_CERT_FILE"
          --tls-client-key-file "$HUBBLE_TLS_CLIENT_KEY_FILE"
        )
        ;;
      *)
        printf 'Instrutor precisa declarar se Relay exige mTLS.\n' \
          >&2
        exit 1
        ;;
    esac
    ;;
  loopback-plaintext)
    if [[ "$HUBBLE_SERVER" != '127.0.0.1:4245' ]]; then
      printf 'Plaintext permitido somente no port-forward loopback.\n' \
        >&2
      exit 1
    fi
    ;;
  *)
    printf 'Instrutor deve declarar o modo de conexão do Relay.\n' >&2
    exit 1
    ;;
esac
record 'modo Hubble declarado pelo instrutor' \
  printf 'HUBBLE_MODE=%s\n' "$HUBBLE_MODE" || exit 1
record 'E03 status Hubble no modo declarado' \
  hubble status --server "$HUBBLE_SERVER" \
  "${HUBBLE_CONNECTION_ARGS[@]}" || exit 1
~~~

~~~{=latex}
\clearpage
~~~

**E03.4 · Terminal A · VM Linux e POD via exec — Gere poucos pedidos**

Gere poucos requests novos no terminal A, sem loop. record guarda a saída e o código de cada pedido, mesmo se um status HTTP provocar curl não zero:

~~~bash
RECORD_STEP='E03.4'
record 'E03 UTC antes do pedido API' \
  date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
if record 'E03 request via API' \
  k exec -n "$LAB_NS" deploy/frontend -- \
  curl --fail-with-body -sS --connect-timeout 3 \
    --max-time 5 -D - http://api/; then
  rc_api=0
else
  rc_api=$?
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes do próximo pedido.\n' >&2
    exit 1
  fi
fi
printf 'E03 request via API rc=%s\n' "$rc_api" \
  | tee -a "$LAB_RECEIPT" || exit 1
record 'E03 UTC antes do pedido direto' \
  date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
if record 'E03 request direto antes de E04' \
  k exec -n "$LAB_NS" deploy/frontend -- \
  curl --fail-with-body -sS --connect-timeout 3 \
    --max-time 5 -D - http://backend/; then
  rc_direct=0
else
  rc_direct=$?
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes do próximo pedido.\n' >&2
    exit 1
  fi
fi
printf 'E03 request direto rc=%s\n' "$rc_direct" \
  | tee -a "$LAB_RECEIPT" || exit 1
~~~

~~~{=latex}
\clearpage
~~~

**E03.5 · Terminal A · VM Linux — Consulte a janela curta de Hubble**

Consulte somente a namespace e uma janela curta, passando explicitamente o mesmo endpoint e os parâmetros do modo declarado usados no teste de status. Mantenha o terminal B aberto para os exercícios de policy e troubleshooting:

~~~bash
RECORD_STEP='E03.5'
record 'E03 Hubble flows no modo do E03' \
  hubble observe --server "$HUBBLE_SERVER" \
  "${HUBBLE_CONNECTION_ARGS[@]}" --namespace "$LAB_NS" \
  --since 2m || exit 1
~~~

**E03.6 · Terminal A · VM Linux — Registre os campos da consulta**

Registre intervalo UTC, filtro, origem/destino, protocolo, verdict e campos ausentes. record salva o retorno de cada comando. Ctrl-C, somente no terminal B, encerra o encaminhamento depois de E05 ou quando o instrutor pedir.

### Confira e registre

**Esperado — ILUSTRATIVO:** `hubble status` conecta no modo declarado e confirma a saúde. Podem surgir fluxos recentes entre frontend e api e entre api e backend; antes da policy, também pode surgir frontend e backend direto. Hubble pode mostrar FORWARDED ou um verdict equivalente e detalhes L7 se estiverem habilitados. A saída exata, nome do processo e metadados variam; nenhuma observação real foi feita.

**Observado — NOT_RUN (ainda não executado)**

- Versões CLI e Relay: \hrulefill
- Modo e confirmação do instrutor, sem segredo: \hrulefill
- Namespace Cilium e endereço local anunciado: \hrulefill
- UTC inicial/final, filtro e janela: \hrulefill
- Origem, destino, protocolo e verdict: \hrulefill
- Pedido correlacionado e código de saída: \hrulefill
- Campos ausentes e limitações: \hrulefill
- Diagnóstico ou resultado inconclusivo: \hrulefill

### Interprete

A janela ajuda a correlacionar um request recente ao fluxo de rede e à decisão observada. Fluxo permitido não prova sucesso HTTP; fluxo descartado sem endereço/tempo correlacionados não prova que foi aquele request; falta de registro pode decorrer de filtro, retenção, configuração ou intervalo.

### Se falhar

Erro de TLS ou conexão significa que o acesso ao Relay não foi estabelecido, não que o tráfego parou. Não altere o modo nem use fallback; pare o port-forward no terminal B com Ctrl-C e peça ao instrutor os parâmetros corretos. Se o instrutor declarou `loopback-plaintext` mas status falhou, registre o erro e pare. Se a consulta não mostrar fluxo, confirme namespace e relógio; no máximo, gere um pedido único adicional com autorização do instrutor. Se seguir ausente, preserve NOT_RUN ou inconclusivo. Não habilite observabilidade nem altere Cilium.

### Critério para seguir

CLI conectou no modo explicitamente confirmado pelo instrutor; poucos requests foram marcados; a saída da janela filtrada foi correlacionada com tempo, namespace, origem/destino e verdict; ou a ausência de dados foi registrada como inconclusiva.

### Gabarito para conferir depois

Hubble mostra eventos de fluxo produzidos pela instrumentação e pela configuração disponíveis. O Relay não substitui captura integral nem audit log de objetos Kubernetes. Timestamp e identidade ajudam correlação; ausência de fluxo sozinho não prova ausência de tráfego.

### Próxima etapa

Terminal B permanece aberto somente com o port-forward. E04 preserva o pedido via API e testa uma conexão direta nova; encerre B depois de E05.

## E04 — Aplicar a policy de ingresso e preservar a cadeia

### Antes de começar

**Objetivo:** permitir somente frontend→api e api→backend por TCP/8080 na entrada dos Pods api e backend, mantendo o caminho pelo proxy e bloqueando o acesso direto do frontend ao backend.

**Pré-requisitos:** E02 saudável e registrada; E03 passou `hubble status` no modo de conexão declarado pelo instrutor; se plaintext foi autorizado, o servidor é loopback 127.0.0.1:4245; policies globais revisadas pelo instrutor; Cilium já configurado; arquivo 40-policies-ingress.yaml conferido. O exercício não altera egress, política global ou namespace.

### Cenário e figura

O pedido pela API deve continuar saudável. O pedido direto do frontend ao backend é a contraprova negativa; timeout isolado não explica por que a tentativa falhou.

**Figura 7 – E04 permite dois trechos e bloqueia o atalho direto**

![Fluxo com três Pods: frontend app=frontend, Pod api que aceita ingresso de app=frontend por TCP/8080, e Pod backend que aceita ingresso de app=api por TCP/8080. Setas sólidas indicam o caminho permitido frontend→api→backend; seta vermelha tracejada indica tentativa direta frontend→backend sem regra de ingresso. Abaixo, uma caixa de contraprovas mostra API HTTP 200 e a necessidade de flow/verdict recente para o acesso direto. Egress está livre neste recorte; policies aplicáveis são aditivas.](diagramas/ebpf-cilium-iniciantes/figura-10-e04-policy.png)

Fonte: elaboração própria (2026), com base em (Kubernetes Authors, 2026), (Cilium Authors, 2026) e nos manifests E04.
Nota: linha sólida/tracejada e rótulos preservam a distinção sem depender de cor.

```{=latex}
\FloatBarrier
```

### Preveja antes de executar

Qual caminho deve continuar saudável depois de aplicar a policy? Que evidência além de um timeout seria necessária para atribuir a falha direta à policy?

**Registre sua previsão antes dos comandos:**

```{=latex}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}
```

### Passos

**E04.1 · Terminal A · VM Linux — Confirme a linha de base**

Confirme E02: a cadeia pela API deve estar saudável e o acesso direto ainda deve funcionar antes da policy. Se não houver linha de base, resolva E02 ou pare.

**E04.2 · Terminal A · VM Linux — Leia e aplique as policies**

Cada policy seleciona um destino pela label app e contém somente ingresso. O número 8080 é a porta do contêiner selecionado, não a porta 80 do Service:

~~~bash
RECORD_STEP='E04.2'
record 'E04 ler manifest de policy' \
  sed -n '1,220p' "$LAB_DIR/40-policies-ingress.yaml" \
  || exit 1
record 'E04 aplicar policies de ingresso' \
  k apply -n "$LAB_NS" -f "$LAB_DIR/40-policies-ingress.yaml" \
  || exit 1
record 'E04 policies presentes' \
  k -n "$LAB_NS" get networkpolicy || exit 1
~~~

~~~{=latex}
\clearpage
~~~

**E04.3 · Terminal A · VM Linux e POD via exec — Teste o caminho positivo**

Abra uma conexão nova para a cadeia positiva pela API. Leia status HTTP e o cabeçalho do proxy:

~~~bash
RECORD_STEP='E04.3'
record 'E04 UTC antes do pedido API' \
  date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
if record 'E04 curl positivo via API' \
  k exec -n "$LAB_NS" deploy/frontend -- \
  curl --fail-with-body -sS --connect-timeout 3 \
    --max-time 5 -D - http://api/; then
  rc_api=0
else
  rc_api=$?
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes do próximo pedido.\n' >&2
    exit 1
  fi
fi
printf 'E04 curl via API rc=%s\n' "$rc_api" \
  | tee -a "$LAB_RECEIPT" || exit 1
~~~

**E04.4 · Terminal A · VM Linux e POD via exec — Teste o caminho direto**

Abra uma conexão nova para o teste direto. Um único request limitado em cinco segundos é suficiente; não faça loop:

~~~bash
RECORD_STEP='E04.4'
record 'E04 UTC antes do pedido direto' \
  date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
if record 'E04 curl negativo direto ao backend' \
  k exec -n "$LAB_NS" deploy/frontend -- \
  curl --fail-with-body -sS --connect-timeout 3 \
    --max-time 5 -D - http://backend/; then
  rc_direct=0
else
  rc_direct=$?
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes do próximo pedido.\n' >&2
    exit 1
  fi
fi
printf 'E04 curl direto rc=%s\n' "$rc_direct" \
  | tee -a "$LAB_RECEIPT" || exit 1
~~~

**E04.5 · Terminal A · VM Linux — Registre resultado e evidência Hubble**

Anote horário, saída curl, status HTTP se houve resposta e destino. Em seguida examine a janela curta de Hubble e as policies efetivamente presentes:

~~~bash
RECORD_STEP='E04.5'
record 'E04 Hubble flows no modo do E03' \
  hubble observe --server "$HUBBLE_SERVER" \
  "${HUBBLE_CONNECTION_ARGS[@]}" --namespace "$LAB_NS" \
  --since 2m || exit 1
record 'E04 objetos e labels do lab' \
  k -n "$LAB_NS" get \
  pods,services,endpointslices,networkpolicy \
  --show-labels || exit 1
~~~

### Confira e registre

**Esperado — ILUSTRATIVO:** a cadeia via API segue com HTTP 200. O acesso direto tende a não receber HTTP; o código curl pode indicar timeout ou outro erro de conexão. Correlacione a tentativa recente, o destino backend e um fluxo DROPPED / Policy denied. Policies do Kubernetes aplicáveis ao mesmo sentido são aditivas, e respostas de conexões permitidas podem retornar; outras policies ou restrições globais podem influir. (Kubernetes Authors, 2026) (Cilium Authors, 2026)

**Observado — NOT_RUN (ainda não executado)**

- UTC e namespace: \hrulefill
- Policy e revisão do manifesto: \hrulefill
- Via API — status, cabeçalho, corpo e código: \hrulefill
- Direto — status se houve, corpo e código: \hrulefill
- Hubble — origem, destino, verdict e horário: \hrulefill
- Condições globais ou observações do instrutor: \hrulefill
- Diagnóstico apoiado por evidência correlacionada: \hrulefill

### Interprete

O Service seleciona o destino; a policy restringe quais Pods podem iniciar a conexão para aquele destino. HTTP 200 pela API verifica o caminho positivo. A falha do curl só demonstra que aquela tentativa não recebeu a resposta esperada; sem evento correlacionado, a causa é inconclusiva. Hubble não substitui o status HTTP da aplicação.

### Se falhar

Se o caminho via API também falhar, confira selectors, labels e ambas permissões; egress ficou fora deste recorte, mas regras globais podem afetar. Se a tentativa direta falhar sem evento correlacionado, não declare bloqueio por policy. Se ela ainda funciona, confirme que o CNI aplica policy aos Pods e que os selectors correspondem. Não remova policies amplas para testar.

### Critério para seguir

Uma chamada nova pela API permanece saudável e o acesso direto falha com evidência recente correlacionada ao backend e verdict de policy, sem mudança de egress ou política global.

### Gabarito para conferir depois

api aceita ingresso de frontend na porta 8080; backend aceita ingresso de api na 8080. O tráfego de resposta pertence a essas conexões permitidas. Frontend não é selecionado pelas duas policies, e nenhuma delas isola egress.

### Próxima etapa

As duas policies permanecem aplicadas. Mantenha Terminal A e o port-forward próprio de B para o laboratório C, que reúne os requisitos de E05 e E06. A falha continua limitada ao selector previsto; a limpeza de E06 permanece assistida.

## Laboratório de revisão C: Diagnosticar e encerrar

Esta revisão reúne E05 e E06 para explicar a falha prevista, restaurar somente o Service e encerrar a mesma rodada com limpeza confirmada pelo instrutor.

> **Ficha C. Estado inicial: NOT_RUN**
>
> **Requisito:** distinguir saúde do Pod de seleção do destino, restaurar o Service e confirmar a remoção da namespace própria.
>
> **Evidência observada:** ainda não coletada.
>
> **Decisão:** pendente até conferir restauração, controles finais e ausência.

**Apoio visual:** Figuras 8 e 9. Cada desenho aparece no exercício correspondente, antes dos comandos.

**Estado de entrada:** cadeia positiva e contraprovas de E04 registradas; policies, namespace, contexto, Terminal A e recibo preservados. Pare se identidade ou baseline divergir.

**Critérios de saída:** relacione Pod Ready/labels/selector/destino; restaure só o Service saudável; confirme API 200 e acesso direto bloqueado. Na limpeza assistida, confirme identidade, namespace ausente e port-forward parado.

**Tarefas por resultado:**

1. **Diagnosticar:** relacione Pod Ready, selector/labels, EndpointSlice e erro da API; use só o selector defeituoso previsto, sem contornar policy.
2. **Restaurar:** recupere apenas o Service saudável; confira EndpointSlice, API positiva e acesso direto ainda bloqueado.
3. **Encerrar com o instrutor:** registre esperado/observado, reconfirme contexto/API/UID/run-id, remova só a namespace própria e pare o port-forward após confirmar ausência.

**Apoio opcional:** E05.1–E05.5/E06.1–E06.5 localizam as verificações; limpeza de E06 é sempre assistida. Não repita a rodada.

**Entregas, diagnóstico e estado de saída:** guarde falha, comparação, restauração e conferência no mesmo recibo, que não é audit log. Após interrupção de mutação, preserve erro/recibo e peça recuperação assistida; identidade ausente ou divergente bloqueia mutação. Ao concluir, namespace própria ausente, port-forward parado e recibo preservado; as soluções não reabrem a rodada.

## E05 — Diagnosticar e restaurar um selector incorreto

### Antes de começar

**Objetivo:** introduzir uma falha controlada no selector do Service backend e mostrar por que um Pod Ready pode deixar de ser destino do Service.

**Pré-requisitos:** baseline E02 registrada; policies de E04 continuam aplicadas e a cadeia positiva funciona; arquivo defeituoso pertence à mesma revisão. Não faça esta falha em namespace ou cluster compartilhado.

### Cenário e figura

O selector errado muda somente quais Pods o Service encontra. O Pod pode continuar Ready, mesmo quando a API não tem destino backend selecionado.

**Figura 8 – E05 separa a saúde do Pod da seleção pelo Service**

![Árvore de diagnóstico: 1 pergunta se o Pod backend está Ready; NÃO leva a investigar probe/Pod e SIM leva à comparação 2 entre label app=backend e selector do Service. Na etapa 2, SIM segue outra hipótese e NÃO evidencia o mismatch. A evidência conduz a EndpointSlice vazio e possível erro pela API; só depois se restaura o YAML saudável do Service e se repetem os controles: API 200 e acesso direto ainda negado pela policy.](diagramas/ebpf-cilium-iniciantes/figura-11-e05-selector.png)

Fonte: elaboração própria (2026), com base em (Kubernetes Authors, 2026) e no exercício E05.
Nota: a árvore orienta a evidência; status HTTP isolado não identifica a causa.

```{=latex}
\FloatBarrier
```

### Preveja antes de executar

Se o Pod backend continuar Ready, mas o Service não encontrar label correspondente, o que você espera ver na EndpointSlice? Anote uma hipótese sobre a resposta da API sem escolher um status HTTP único.

**Registre sua previsão antes dos comandos:**

```{=latex}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}
```

### Passos

**E05.1 · Terminal A · VM Linux — Confirme a linha de base sem repetir o pedido**

Use como linha de base o pedido via API já registrado em E04; confirme que foi saudável e que o backend está Ready. Não gere outro pedido só para repetir o registro. Se a linha de base já falhava, não introduza outra falha.

**E05.2 · Terminal A · VM Linux — Aplique somente o selector defeituoso**

Esse arquivo muda somente o selector; não altera Pod, Deployment nem policies:

~~~bash
RECORD_STEP='E05.2'
record 'E05 aplicar selector defeituoso' \
  k apply -n "$LAB_NS" \
  -f "$LAB_DIR/41-backend-service-defeito.yaml" || exit 1
~~~

**E05.3 · Terminal A · VM Linux — Compare Pod, selector e destinos**

Compare labels do Pod e selector do Service. Leia também os endpoints e readiness:

~~~bash
RECORD_STEP='E05.3'
record 'E05 Pod labels' \
  k -n "$LAB_NS" get pods -l app=backend --show-labels || exit 1
record 'E05 Service selector' \
  k -n "$LAB_NS" get service backend -o yaml || exit 1
record 'E05 EndpointSlice' \
  k -n "$LAB_NS" get endpointslice \
  -l kubernetes.io/service-name=backend -o yaml || exit 1
record 'E05 readiness backend' \
  k -n "$LAB_NS" rollout status deployment/backend \
  --timeout=30s || exit 1
record 'E05 logs API recentes' \
  k -n "$LAB_NS" logs deployment/api --since=2m || exit 1
~~~

**E05.4 · Terminal A · VM Linux e POD via exec — Registre a falha pelo proxy**

Faça uma chamada pela API, registre código de saída e status HTTP se presente. Não tente corrigir a falha usando acesso direto: E04 continua selecionando o Pod backend e bloqueando esse atalho:

~~~bash
RECORD_STEP='E05.4'
record 'E05 UTC antes do pedido com defeito' \
  date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
if record 'E05 request API com selector defeituoso' \
  k exec -n "$LAB_NS" deploy/frontend -- \
  curl --fail-with-body -sS --connect-timeout 3 \
    --max-time 5 -D - http://api/; then
  rc_fault=0
else
  rc_fault=$?
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes do próximo pedido.\n' >&2
    exit 1
  fi
fi
printf 'E05 request com defeito rc=%s\n' "$rc_fault" \
  | tee -a "$LAB_RECEIPT" || exit 1
~~~

~~~{=latex}
\clearpage
~~~

**E05.5 · Terminal A · VM Linux e POD via exec — Restaure só o Service e refaça os controles**

Restaure somente o Service saudável e repita os dois controles. Não reaplique tudo e não reinicie Deployment:

~~~bash
RECORD_STEP='E05.5'
record 'E05 restaurar Service saudável' \
  k apply -n "$LAB_NS" \
  -f "$LAB_DIR/10-backend-service.yaml" || exit 1
record 'E05 verificar Service restaurado' \
  k -n "$LAB_NS" get service backend -o yaml || exit 1
record 'E05 verificar EndpointSlice restaurado' \
  k -n "$LAB_NS" get endpointslice \
  -l kubernetes.io/service-name=backend || exit 1
record 'E05 UTC antes do pedido API restaurado' \
  date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
if record 'E05 request API após restauração' \
  k exec -n "$LAB_NS" deploy/frontend -- \
  curl --fail-with-body -sS --connect-timeout 3 \
    --max-time 5 -D - http://api/; then
  rc_api=0
else
  rc_api=$?
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes do próximo pedido.\n' >&2
    exit 1
  fi
fi
printf 'E05 request API restaurado rc=%s\n' "$rc_api" \
  | tee -a "$LAB_RECEIPT" || exit 1
record 'E05 UTC antes do pedido direto' \
  date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
if record 'E05 request direto sob policy' \
  k exec -n "$LAB_NS" deploy/frontend -- \
  curl --fail-with-body -sS --connect-timeout 3 \
    --max-time 5 -D - http://backend/; then
  rc_direct=0
else
  rc_direct=$?
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes do próximo pedido.\n' >&2
    exit 1
  fi
fi
printf 'E05 request direto rc=%s\n' "$rc_direct" \
  | tee -a "$LAB_RECEIPT" || exit 1
~~~

### Confira e registre

**Esperado — ILUSTRATIVO:** o Pod backend permanece Ready; sem correspondência de label, o Service perde destino correspondente e a chamada via API pode falhar. Depois da restauração, o EndpointSlice volta a refletir o Pod pronto, a chamada via API retorna HTTP 200 e a chamada direta continua bloqueada pela policy. EndpointSlices são gerados a partir dos Pods que correspondem ao selector do Service. (Kubernetes Authors, 2026)

**Observado — NOT_RUN (ainda não executado)**

- UTC da linha de base e da tentativa: \hrulefill
- Labels do Pod e selector antes/depois: \hrulefill
- Destinos e condição na EndpointSlice: \hrulefill
- Readiness do backend: \hrulefill
- Falha via API — status se houve e código: \hrulefill
- Service restaurado e EndpointSlice: \hrulefill
- API restaurada — status, cabeçalho e código: \hrulefill
- Acesso direto pós-policy — status se houve e código: \hrulefill
- Diagnóstico ou hipótese não confirmada: \hrulefill

### Interprete

Readiness é uma pergunta local sobre a probe do Pod; selector e EndpointSlice descrevem a seleção feita pelo Service. Um processo saudável pode estar sem destino associado. A restauração de um único objeto testa se a hipótese explica a falha sem remover as policies.

### Se falhar

Se a probe backend falhar, pare: não é apenas uma falha de selector. Se a EndpointSlice ainda tiver destino, compare label, selector, Service e condição do endpoint. Se a chamada não falhar, preserve essa observação e peça ajuda ao instrutor; pode existir outro Service ou resolução diferente. Se a restauração não devolver o destino, confira somente o YAML saudável e a probe do Pod e peça ajuda.

Se a sessão for interrompida depois de uma mutação, não retome com base no estado parcial. Preserve a saída, o erro e o recibo e peça recuperação assistida ao instrutor. Antes de qualquer restauração, reconfira nos registros originais o contexto, o API server, os UIDs do cluster e da namespace e o run-id. Se qualquer identidade estiver ausente, divergente ou desconhecida, não altere o ambiente. Com a identidade confirmada, siga somente a restauração do Service saudável e os controles previstos em E05.5. Não use trap automático, retomada por suposição, rollout restart, remoção ampla ou force.

### Critério para seguir

A sequência Pod Ready → selector não corresponde → nenhum destino pronto → chamada via API falha é observável; restaurar somente o Service recupera o caminho permitido e mantém o acesso direto negado.

### Gabarito para conferir depois

Um Deployment mantém o Pod, mas o Service escolhe por labels. EndpointSlice expõe destinos que o control plane associou ao Service. O selector errado interrompe a seleção lógica sem exigir editar ou matar o Pod. A resposta HTTP específica depende da implementação e não prova sozinha a causa.

### Próxima etapa

O Service saudável e as policies permanecem; Terminal A conserva a identidade e o recibo. E06 confere a trilha escrita e, depois de reconfirmar UID e run-id, limpa a namespace própria.

## E06 — Auditar a evidência e limpar somente a própria namespace

### Antes de começar

**Objetivo:** produzir um recibo local mínimo que distingue intenção, observação e conclusão, e remover somente a namespace desta rodada após confirmar UID e run-id.

**Pré-requisitos:** registros E01–E05; terminal A mantém o mesmo contexto, namespace, run-id e UID; todas as políticas e objetos do laboratório foram inventariados; instrutor está disponível. Se a sessão do shell foi perdida ou a identidade não confere, não execute cleanup.

### Cenário e figura

O recibo local registra o que o participante anotou. O audit log do API server é produzido por configuração administrativa e não é coletado por este exercício.

**Figura 9 – E06 mantém o recibo local separado do audit log do control plane**

![Sequência numerada: registrar intenção e revisão; hash de cada manifest; escrever comando, horário e exit code; separar esperado e observado; registrar conclusão limitada; conferir cluster, UID e run-id; apagar somente a namespace própria e esperar a remoção. Duas caixas distintas mostram o recibo local preenchido pelo aluno e o audit log produzido pelo API server se configurado; uma nota limita o que o recibo prova.](diagramas/ebpf-cilium-iniciantes/figura-12-e06-auditoria-cleanup.png)

Fonte: elaboração própria (2026), com base em (Kubernetes Authors, 2026) e no processo de evidência E06.
Nota: o exercício não habilita, altera ou coleta audit log do control plane.

```{=latex}
\FloatBarrier
```

### Preveja antes de executar

Qual informação permite distinguir esperado de observado? Um recibo escrito localmente prova, sozinho, que o API server manteve um audit log?

**Registre sua previsão antes dos comandos:**

```{=latex}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}\par\vspace{0.55cm}
\noindent\rule{\textwidth}{0.35pt}
```

### Passos

**E06.1 · Terminal A · VM Linux — Confira e complete o recibo local**

E01 criou o arquivo local `receipt.md` antes da primeira chamada ao API server, com permissões restritas. Confira que o mesmo arquivo está presente; não crie um segundo recibo. Os comandos `record` seguintes acrescentam revisão do guia, exercício e passo, rótulo, saída e código de saída. Não escrevem os argumentos expandidos, que podem conter caminhos locais. O modo 700 restringe a leitura no sistema de arquivos, mas não prova autoria nem fornece custódia imutável:

~~~bash
RECORD_STEP='E06.1'
if [[ ! -f "$LAB_RECEIPT" || ! -d "$LAB_RECEIPT_DIR" ]]; then
  printf 'Recibo E01 ausente; pare e chame o instrutor.\n' >&2
  exit 1
fi
record 'E06 hora UTC' date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
record 'E06 versão Kubernetes' k version || exit 1
record 'E06 hashes do guia e manifests' \
  sha256sum "$LAB_GUIDE_REL" "$LAB_DIR_REL"/*.yaml || exit 1
record 'E06 inventário final com labels' \
  k -n "$LAB_NS" get \
  pods,services,endpointslices,networkpolicy --show-labels || exit 1
pod_columns='custom-columns=NAME:.metadata.name,'
pod_columns+='IMAGE:.spec.containers[*].image,'
pod_columns+='IMAGE_ID:.status.containerStatuses[*].imageID,'
pod_columns+='NODE:.spec.nodeName'
node_columns='custom-columns=NAME:.metadata.name,'
node_columns+='ARCH:.status.nodeInfo.architecture,'
node_columns+='OS:.status.nodeInfo.osImage'
if ! record 'E06 imageIDs e nós dos Pods' \
  k -n "$LAB_NS" get pods -o "$pod_columns"; then
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes de continuar.\n' >&2
    exit 1
  fi
  printf 'ImageIDs não coletados; marque NOT_RUN e explique.\n' \
    | tee -a "$LAB_RECEIPT" || exit 1
fi
if ! record 'E06 arquitetura e SO dos nós' \
  k get nodes -o "$node_columns"; then
  if (( RECORD_LOG_FAILED )); then
    printf 'Recibo falhou; pare antes de continuar.\n' >&2
    exit 1
  fi
  printf 'Arquitetura não coletada; marque NOT_RUN e explique.\n' \
    | tee -a "$LAB_RECEIPT" || exit 1
fi
~~~

**E06.2 · Terminal A · VM Linux — Separe esperado, observado e conclusão**

E01 já registrou `kubectl version`; o status Hubble do E03 registra a versão anunciada pelo Relay. Confirme esses registros e acrescente a revisão, versão do guia e conclusão. Para cada observação, mantenha rótulo da etapa, UTC, código de saída, status HTTP se houver, valor esperado, saída observada e conclusão limitada. Registre NOT_RUN (ainda não executado) ou inconclusivo quando uma verificação não ocorreu. Não copie kubeconfig, token, certificados, chaves, Secrets ou caminhos pessoais para uma cópia compartilhada do recibo.

**E06.3 · Terminal A · VM Linux — Reconfirme as identidades antes de limpar**

Antes de apagar, compare mais uma vez o API server e UID kube-system com o recibo, depois compare o UID e a label run-id atuais com os valores da sessão. Os testes encerram o shell com erro em qualquer divergência:

~~~bash
actual_context="$(k config view --minify \
  -o jsonpath='{.contexts[0].name}')" || exit 1
actual_server="$(k config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}')" || exit 1
actual_cluster_uid="$(k get namespace kube-system \
  -o jsonpath='{.metadata.uid}')" || exit 1
actual_ns_uid="$(k get namespace "$LAB_NS" \
  -o jsonpath='{.metadata.uid}')" || exit 1
actual_run_id="$(k get namespace "$LAB_NS" \
  -o jsonpath='{.metadata.labels.lab\.learn-cilium\.org/run-id}')" \
  || exit 1
if [[ "$actual_context" != "$LAB_CONTEXT" ||
      "$actual_server" != "$LAB_API_SERVER" ||
      "$actual_cluster_uid" != "$LAB_CLUSTER_UID" ||
      "$actual_ns_uid" != "$LAB_NS_UID" ||
      "$actual_run_id" != "$LAB_RUN_ID" ]]; then
  printf 'Identidade divergente; não apague. Chame o instrutor.\n' >&2
  exit 1
fi
~~~

**E06.4 · Terminal A · VM Linux — Limpe somente a namespace confirmada**

Se todos os valores conferirem e o instrutor liberar o encerramento, peça ao Kubernetes para apagar somente a namespace nominal. Não use `--force`, finalizers, delete all, selector amplo ou política global:

~~~bash
RECORD_STEP='E06.4'
record 'E06 UTC antes do cleanup' \
  date -u +%Y-%m-%dT%H:%M:%SZ || exit 1
record 'E06 solicitar delete sem espera implícita' \
  k delete namespace "$LAB_NS" --wait=false || exit 1
record 'E06 aguardar remoção limitada a 120s' \
  k wait --for=delete "namespace/$LAB_NS" \
  --timeout=120s || exit 1
remaining_namespaces="$(k get namespaces -o name)" || exit 1
printf 'E06 conferência final de namespace exit_code=0\n' \
  | tee -a "$LAB_RECEIPT" || exit 1
if printf '%s\n' "$remaining_namespaces" \
  | grep -Fxq -- "namespace/$LAB_NS"; then
  printf 'Namespace ainda aparece; não force remoção.\n' >&2
  exit 1
fi
printf 'Namespace própria ausente após o wait.\n' \
  | tee -a "$LAB_RECEIPT" || exit 1
~~~

**E06.5 · Terminal A · VM Linux — Registre o resultado da limpeza**

Anote hora e código de saída. Se houver timeout, pare e comunique o instrutor; não force finalizers. O wait confirma a remoção observável do objeto namespace, não auditoria imutável nem exclusão de cópias do recibo local.

### Confira e registre

**Esperado — ILUSTRATIVO:** o recibo contém a trilha pretendida e observada sem credenciais; os guardas comparam contexto, endpoint, UIDs e run-id; a namespace própria desaparece após o pedido de remoção. Nada neste exercício prova que o API server tinha audit habilitado.

**Observado — NOT_RUN (ainda não executado)**

- Revisão e hashes do guia/manifests: \hrulefill
- UTC, versões e identidade conferida: \hrulefill
- Etapas, comandos e códigos de saída: \hrulefill
- Esperado e observado, em campos separados: \hrulefill
- Limitações e dados ainda não executados: \hrulefill
- UID e run-id antes da limpeza: \hrulefill
- Pedido, wait e UTC final: \hrulefill
- Namespace própria ausente: \hrulefill
- Diagnóstico, limitações e lacunas: \hrulefill

### Interprete

O recibo local é uma nota produzida pelo participante; ele ajuda outra pessoa a seguir o raciocínio se seus limites e lacunas forem explícitos. Audit log Kubernetes é registro do API server e depende de configuração e política do cluster. Uma coisa não substitui a outra. UID e run-id tornam a limpeza mais estreita, mas não autorizam remover qualquer recurso fora da namespace própria.

### Se falhar

Se a identidade, UID ou label divergir, não apague e chame o instrutor. Se o wait exceder o tempo, não force nem remova finalizers. Se não conseguir confirmar ausência, registre resultado inconclusivo. Se o recibo contiver credencial, não o distribua; peça orientação para tratamento seguro.

### Critério de conclusão

O recibo local separa esperado de observado, contém hashes, horários, versões, etapas, códigos e limitações sem segredo. A namespace só foi apagada após reconferir contexto, cluster, UID e run-id; o wait e a lista final confirmaram ausência.

**Perguntas para revisar o percurso**

1. Qual a diferença entre readiness de um Pod e a existência de um destino pronto no EndpointSlice?
2. Por que o Service backend deve preceder a inicialização do NGINX da API neste cenário?
3. O que um erro curl prova, e que evidência adicional ajuda a atribuí-lo à policy?
4. Um recibo local de comandos é um audit log do API server?

### Gabarito para conferir depois

Log local registra o que o participante escolheu anotar; audit log do API server registra eventos conforme a configuração administrativa. O comando de limpeza atua somente sobre a namespace confirmada e espera sua remoção normal. Sem confirmação da configuração de auditoria do control plane, não se pode afirmar que eventos de API foram retidos.

**Respostas da revisão:** (1) readiness é a resposta à probe configurada no Pod; a EndpointSlice contém destinos associados ao selector do Service. (2) a configuração NGINX consulta o nome DNS backend no início; o Service cria esse nome estável antes do Pod proxy iniciar. (3) o erro prova que a tentativa não recebeu a resposta esperada; timestamp, destino e verdict correlacionados ajudam a investigar a causa. (4) não; audit log é produzido pelo API server segundo configuração administrativa, recibo é uma nota local.

### Erro comum

Chamar todo erro de rede de “policy drop” ou limpar recursos sem confirmar identidade. Colete a próxima evidência que separa hipóteses; não aumente o alcance de uma correção para fazer o sintoma desaparecer.

### Resumo

O caminho tem várias camadas: processo, DNS, Service, EndpointSlice, proxy, Pod e policy. Cada ferramenta responde uma pergunta limitada. Uma chamada positiva, uma tentativa negativa correlacionada, a restauração estreita e uma limpeza guardada completam a trilha.

### Glossário consultável

- **Deployment:** mantém Pods declarados.
- **Service:** nome e seleção lógica de destinos.
- **EndpointSlice:** lista parcial de destinos associados ao Service.
- **Label / selector:** chave-valor que identifica / regra que seleciona objetos.
- **ConfigMap:** configuração não secreta.
- **Probe:** verificação local de aplicação.
- **NetworkPolicy:** regra de tráfego para Pods selecionados.
- **Hubble:** observabilidade de fluxos do Cilium.
- **Audit log:** eventos do API server conforme a política do cluster.

### Leituras

Probes, Services, DNS, EndpointSlices, NetworkPolicy, segurança de Pods e auditoria no Kubernetes; Hubble e troubleshooting no Cilium.

### Próxima etapa

Depois da limpeza assistida em E06.5, confira o recibo da mesma rodada e leia as soluções comentadas A, B e C como interpretação das evidências reunidas. Não repita os passos nem abra uma nova namespace. Se uma observação não ocorreu, mantenha NOT_RUN ou inconclusivo; consultar apoio não é reprovação.

~~~{=latex}
\clearpage
~~~

## Soluções comentadas A, B e C

Esta seção interpreta o recibo da única rodada. Não acrescenta comandos nem preenche observações ausentes; mantenha NOT_RUN ou inconclusivo quando faltar evidência.

### Solução A: Comprovar a cadeia

Em E01.5/E01.7, revisão, UTC, contexto, API server, confirmação do instrutor e UIDs/run-id identificam a rodada. O texto impresso por E01.7 é só marcador: sem confirmação, revisão e hora no recibo, não se cria a namespace.

E02.3–E02.5 comparam probes, Service, EndpointSlice e rotas. HTTP 200 com o mesmo corpo indica respostas saudáveis naquele momento; só a API traz `X-Lab-Route: via-api-proxy`. Divergências pedem o diagnóstico de E02; a lista de Pods não prova a cadeia.

### Solução B: Observar e restringir

E03.3a/b registram o modo do Relay; E03.4 marca pedidos; E03.5/3.6 registram fluxo filtrado, identidades, protocolo e verdict. UTC e identidade fazem a correlação. Campo L7 ausente é neutro se não habilitado; sem fluxo correlacionável, a conclusão é inconclusiva.

E04.3–E04.5 contrastam API positiva e acesso direto. Evento recente para backend com verdict de policy sustenta a hipótese; timeout só indica falta de resposta. Sem tempo ou identidade suficientes, não infira enforcement pelo erro do cliente.

### Solução C: Diagnosticar e encerrar

E05.3 relaciona prontidão do Pod, selector/labels e EndpointSlice. Pod Ready sem destino é compatível com falha de seleção, mas erro da API não prova a causa. E05.5 restaura só o Service saudável; confira EndpointSlice, API e acesso direto sob as policies de E04.

E06.1–E06.5 seguem assistidos. Reconfirme contexto, API server, UIDs e run-id antes de limpar; identidade desconhecida bloqueia mutação. O wait confirma ausência observável, não audit log. Pare o port-forward próprio e interprete o recibo sem reabrir a rodada.

~~~{=latex}
\clearpage
~~~

## Prévia: como eBPF responde a eventos

Esta prévia acompanha um programa eBPF — um programa restrito que o kernel Linux pode carregar — do pedido de carga até um evento. O kernel é o núcleo do Linux; hook é um ponto previsto de ligação, e evento é a ocorrência que chega àquele contexto. Espaço de usuário é a área fora do kernel onde processos executam; ali, o agente do Cilium configura componentes, enquanto o programa ligado ao hook atua no contexto do kernel. O caminho exato depende do tipo de programa e da configuração.

Vocabulário de configuração: YAML é um formato textual para dados. No Kubernetes, label (rótulo) é um par chave/valor de metadados que ajuda a identificar e selecionar objetos, mas não autentica; no exemplo ilustrativo `app: api`, `app` é a chave e `api` é o valor (Kubernetes Authors, 2026). Um manifesto Kubernetes é um documento declarativo que descreve um recurso; policy (política de tráfego) é uma regra declarada para controlar comunicações (Cilium Authors, 2026). Nas citações autor-data, 2026 é o ano de consulta quando a página não informa o ano de publicação; `[s.d.]` nas referências conserva essa ausência sem inventar data.

As figuras são modelos didáticos originais. O fragmento YAML e os nomes `frontend`, `api` e `backend` são exemplos ilustrativos; não descrevem um cluster observado. A documentação stable do Cilium consultada em 28 de outubro de 2026 indicava 1.20.4; isso é referência documental, não versão instalada ou executada.

### Um programa eBPF encontra seu evento

#### O que você vai aprender

Ao final, você poderá:

- explicar com palavras simples o que é um hook e onde um programa eBPF se conecta;
- ordenar solicitação de carga, verificação, aceitação ou rejeição, attach e execução por evento;
- distinguir o que a aprovação do verifier indica daquilo que ela não prova, e separar o agente Cilium do datapath.

**Pré-requisito:** nenhum cluster ou terminal. Leia a sequência como um modelo conceitual; ela não é uma receita de instalação.

#### Palavras antes do jargão

**Quadro 1 – Vocabulário em uma frase**

| Termo | Definição curta e limite |
|---|---|
| Kernel / eBPF | O kernel é o núcleo do Linux; eBPF carrega programas restritos que respondem a certos eventos. |
| Hook / evento | Hook é um ponto previsto de ligação; evento é a ocorrência que chega a esse contexto. |
| Verifier / mapa | Verifier analisa propriedades de segurança na carga; mapa guarda valores associados a chaves. |
| Attach / JIT | Attach liga um programa aceito ao hook; JIT compila para instruções nativas quando aplicável. |
| Agente / datapath | O agente Cilium configura componentes; o datapath processa tráfego. Cada um tem um papel diferente. |

Fonte: Elaboração própria (2026), com base em (eBPF Foundation, 2026), (Linux Kernel Documentation, 2026) e (Cilium Authors, 2026).

#### Um ponto de ligação, dois papéis

A analogia do hook como ponto de conexão ajuda a localizar o attach; ele não é um guarda geral, e contexto e resultado variam por tipo.

**Figura 10 – O agente configura; o programa atua no hook**

![Duas faixas: acima, o agente Cilium em espaço de usuário configura ou associa componentes e pode preparar programas eBPF; abaixo, no datapath do kernel Linux, evento → hook → programa eBPF → ação possível conforme o tipo. Uma faixa inferior mostra um trecho YAML ilustrativo e esclarece que é metadado apenas, não manifesto nem policy aplicada.](diagramas/ebpf-cilium-iniciantes/figura-01-papeis.png)

Fonte: Elaboração própria (2026), com base em (Cilium Authors, 2026), (eBPF Foundation, 2026) e (Kubernetes Authors, 2026).

```{=latex}
\FloatBarrier
```

Leitura da Figura 10: agente configura; no kernel, evento → hook → programa → ação por tipo. O fragmento YAML `metadata: {labels: {app: api}}` é ilustrativo, não manifesto nem policy aplicada; label não autentica. (Kubernetes Authors, 2026).

#### Da solicitação ao evento

No modelo temporal, um loader em espaço de usuário solicita a carga ao kernel. O verifier do kernel analisa o programa; se rejeita, a tentativa termina. Se aceita, o kernel pode compilar com JIT quando aplicável. Então o loader solicita attach, o kernel associa o programa ao hook e um evento compatível chega ao hook, onde o programa executa no contexto do kernel. Esta é uma sequência didática, pois os mecanismos de carga e attach variam por tipo de programa. (eBPF Foundation, 2026; Linux Kernel Documentation, 2026; Cilium Authors, 2026)

No caminho rejeitado, a tentativa termina; no caminho aceito, JIT permanece condicional e o loader pede attach ao kernel.

**Figura 11 – Sequência temporal: loader, kernel e hook**

![Diagrama temporal de cima para baixo com loader em espaço de usuário, kernel eBPF com verifier/JIT, hook e evento compatível. O loader pede carga; o verifier analisa; rejeição encerra; na aceitação, JIT pode ocorrer quando aplicável, o loader pede attach e o kernel associa programa ao hook. Depois o evento chega ao hook e o programa executa nesse contexto. Os mecanismos variam por tipo.](diagramas/ebpf-cilium-iniciantes/figura-02-sequencia.png)

Fonte: Elaboração própria (2026), com base em (eBPF Foundation, 2026) e (Linux Kernel Documentation, 2026).

```{=latex}
\FloatBarrier
```


#### Aceito ou rejeitado: o alcance do verifier

O verifier analisa tipos, estado, acessos à memória e caminhos. Se não prova as condições aplicáveis, rejeita a carga. Se aceita, o programa passou nessas verificações; isso não confirma a intenção lógica. (Linux Kernel Documentation, 2026).

**Tabela 1 – Verificações e limites da conclusão**

| O verifier analisa | Isso ajuda a estabelecer | Continua sem prova |
|---|---|---|
| Tipos e estado | uso compatível dos valores acompanhados | que a regra de negócio é a desejada |
| Acessos à memória | respeito aos limites verificados | que um serviço respondeu corretamente |
| Caminhos do programa | que os caminhos analisados atendem às restrições | que o tráfego terá o resultado esperado |

Fonte: Elaboração própria (2026), com base em (Linux Kernel Documentation, 2026).

Leitura do fluxo: se as propriedades não são provadas, a carga é rejeitada; se são, o programa pode seguir para attach, sem validar a lógica desejada.

**Figura 12 – Decisão do verifier e limite da conclusão**

![Fluxo de decisão: pedido de carga chega ao verifier, que examina propriedades verificáveis; os ramos SIM e NÃO levam a aceito e rejeitado. Uma faixa final declara que aceitação não prova a lógica desejada.](diagramas/ebpf-cilium-iniciantes/figura-03-decisao.png)

Fonte: Elaboração própria (2026), com base em (Linux Kernel Documentation, 2026).

```{=latex}
\FloatBarrier
```

~~~{=latex}
\clearpage
~~~

#### Pratique e confira

**Exercício conceitual (15 minutos).** Ordene: (B) solicitar carga, (D) verifier, (F) aceitar/rejeitar, (A) attach, (C) evento e (E) execução. Identifique qual etapa aparece como condicional e em que ponto da sequência ocorre; não execute comandos.

**Gabarito comentado:** B → D → F; rejeitado, termina. Aceito: a etapa JIT aparece depois da aceitação e antes do attach, quando aplicável; então vêm attach, evento e execução (A → C → E). Isso não prova que a lógica é correta.

**Perguntas para recordar e transferir:** (1) Hook e evento são iguais? (2) O que o verifier analisa? (3) O que a aceitação não prova? (4) Como diferem agente e datapath?

**Erro comum:** “O verifier aceitou, então a policy está correta.” A conclusão não decorre da verificação: uma análise de segurança de execução não valida, por si só, a intenção lógica ou o comportamento completo da aplicação.

**Resumo:** o agente configura componentes; o kernel verifica a carga; attach conecta programa e hook; um evento compatível pode executar o programa; aceitar não prova a lógica.

## Referências

BusyBox Authors. HTTP server applet (`httpd`) no manual BusyBox. [s.d.]. Acesso em: 28 out. 2026. Disponível em: [BusyBox manual](https://busybox.net/BusyBox.html).

Cilium Authors. Documentação stable 1.20.4: troubleshooting, Hubble Relay, TLS, Network Policy e observabilidade. [s.d.]. Acesso em: 28 out. 2026. Disponível em: [troubleshooting](https://docs.cilium.io/en/stable/operations/troubleshooting/), [Hubble setup](https://docs.cilium.io/en/stable/observability/hubble/setup/), [Hubble TLS](https://docs.cilium.io/en/stable/observability/hubble/configuration/tls/), [network policy](https://docs.cilium.io/en/stable/security/policy/).

eBPF Foundation. What is eBPF? [s.d.]. Acesso em: 28 out. 2026. Disponível em: [ebpf.io/what-is-ebpf](https://ebpf.io/what-is-ebpf/).

GNU Project. Bash Reference Manual, versão 5.3. 2025. Disponível em: [quoting](https://www.gnu.org/software/bash/manual/html_node/Quoting.html), [shell parameters](https://www.gnu.org/software/bash/manual/html_node/Shell-Parameters.html), [exit status](https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html). Acesso em: 28 out. 2026.

IETF. RFC 1034: Domain Names — Concepts and Facilities. 1987. Disponível em: [RFC 1034](https://www.rfc-editor.org/rfc/rfc1034). Acesso em: 28 out. 2026.

IETF. RFC 4632: Classless Inter-domain Routing (CIDR). 2006. Disponível em: [RFC 4632](https://www.rfc-editor.org/rfc/rfc4632). Acesso em: 28 out. 2026.

IETF. RFC 9110: HTTP Semantics; RFC 9293: Transmission Control Protocol (TCP). 2022. Disponível em: [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110) e [RFC 9293](https://www.rfc-editor.org/rfc/rfc9293). Acesso em: 28 out. 2026.

Kubernetes Authors. Documentação: labels/selectors, Pods, Services, DNS, EndpointSlices, probes, NetworkPolicy, segurança de Pods e audit logging. [s.d.]. Acesso em: 28 out. 2026. Disponível em: [labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/), [Pods](https://kubernetes.io/docs/concepts/workloads/pods/), [Services](https://kubernetes.io/docs/concepts/services-networking/service/), [DNS](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/), [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/), [probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/), [NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/), [security context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/) e [audit logging](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/).

Linux Kernel Documentation. BPF verifier e BPF maps. [s.d.]. Acesso em: 28 out. 2026. Disponível em: [BPF verifier](https://docs.kernel.org/bpf/verifier.html) e [BPF maps](https://docs.kernel.org/bpf/maps.html).

Linux man-pages project. namespaces(7) e cgroups(7). [s.d.]. Acesso em: 28 out. 2026. Disponível em: [namespaces](https://man7.org/linux/man-pages/man7/namespaces.7.html) e [cgroups](https://man7.org/linux/man-pages/man7/cgroups.7.html).

NGINX Container Project. NGINX unprivileged container: uso e diretórios graváveis. [s.d.]. Acesso em: 28 out. 2026. Disponível em: [README](https://github.com/nginx/docker-nginx-unprivileged/blob/main/README.md).
