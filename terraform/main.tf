variable "mio_ip_casa" {
	description = "Il mio ip pubblico per SSH"
	type	= string
}

# --- 1. Configurazione del provider
terraform {
	required_providers {
		aws = {
			#diciamo a terraform di scaricare il plugin ufficiale di amazon
			source = "hashicorp/aws"
			version = "~> 5.0"
		}
	}
}

provider "aws" {
	#impostiamo la regione di default
	region = "us-east-1"
}

#2. --- Allarme costi (AWS BUDGET)
resource "aws_budgets_budget" "zero_cost_alert" {
	#nome tecnico che diamo all'allarme dentro la console AWS
	name = "allarme-costi-zero"
	#diciamo che vogliamo monitorare i costi
	budget_type	= "COST"
	#limite massimo che ci imponiamo
	limit_amount	= "0.01"
	limit_unit	= "USD"
	#intervallo temporale in cui calcolare questo budget
	time_unit	= "MONTHLY"

	#3. --- Regola notifica
	notification {
	#l'allarme scatta quando la spesa è maggiore del limite
		comparison_operator	= "GREATER_THAN"
	#scatta esattamente al 100% del nostro budget
		threshold	= 100
		threshold_type	= "PERCENTAGE"
	#avviso su costi reali non previsti
		notification_type	= "ACTUAL"
	#indirizzo email a cui Amazon invierà la notifica di emergenza
		subscriber_email_addresses = ["alessioercolano6@gmail.com"]
	}
} 

#4. --- Rete Privata (VPC = Virtual Private Cloud)
#resource = dice al sistema di creare un oggetto fisico o logico nuovo che prima non esisteva"
#"aws_vpc" = il nome tecnico ufficiale nel dizionario Amazon per le VPC. Terraform capisce che deve chiamare le API di rete di AWS
#"mia_rete_k8s" = nome locale che usiamo dentro il codice. Ci servirà più avanti quando Terraform dovrà creare il server all'interno della rete "la_mia_rete_k8s"
resource "aws_vpc" "mia_rete_k8s" {
	#assegniamo un blocco di indirizzi IP alla nostra rete (circa 65000 IP disponibili)
	#cidr_block = definisce la grandezza della rete
	#"10.0.0.0/16" = è uno standard di rete. Significa che questa rete avrà a disposizione tutti gli indirizi IP che vanno da 10.0.0.0 a 10.0.255.255. La rete è enorme ed è sufficiente per ospitare migliaia di server in futuro
	cidr_block	= "10.0.0.0/16"
	#abilitiamo il supporto per i nomi di domino (DNS) interni
	#enable_dns_support = AWS fornisce un servizio di risoluzione nomi DNS interno gratuito. Impostato su "true" permettiamo ai futuri server di potersi chiamare per nome invece che tramite i difficili numeri IP
	#enable_dns_hostnames = quando accenderemo un server in questa rete, genererà in automatico un indirizzo web testuale (es. https://www.google.com/search?q=ec2-198-51-100-1.compute.amazonaws.com). Servirà per collegarsi al server da terminale
	enable_dns_support	= true
	enable_dns_hostnames	= true
	#tags = sono etichette. Mentre "mia_rete_k8s" è il nome usato nel codice, questo tag Name è il nome che vedremo fisicamente scritto nella console web di AWS
	tags = {
		Name = "vpc-cluster-k8s"
	}
}


#5. --- Sottorete (Subnet pubblica)
resource "aws_subnet" "subnet_pubblica" {
	#diciamo a terraform di collegare questa sottorete alla rete principale
	#"vpc_id = aws_vpc.mia_rete_k8s.id" = leghiamo due risorse. Stiamo dicendo a terraform di leggere l'ID univoco della VPC creata nel blocco 4 (aws_vpc.mia_rete_k8s) e di incollarlo qui
	vpc_id	= aws_vpc.mia_rete_k8s.id
	#prendiamo dei bit riservati agli host per darli alla rete, in questo modo creiamo delle sottoreti
	#"cidr_block = 10.0.1.0/24" = abbiamo a disposizione da 10.0.1.0 a 10.0.1.255
	cidr_block	= "10.0.1.0/24"
	#scegliamo in quale data center fisico costruire
	#"availability_zone = us-east-1a" = è la regione (Nord Virginia). La lettera a indica il singolo, specifico e fisico Data Center (capannone) in Virginia
	availability_zone	= "us-east-1a"
	#assegnamo in automatico un IP pubblico ai server
	#"map_public_ip_on_launch = true" = senza questa riga true il futuro server EC2 nascerebbe invisibile e isolato (utile per un database segreto, ma non per un server web)
	map_public_ip_on_launch = true
	tags = {
		Name = "subnet-pubblica-k8s"
	}
}


#6. --- Gateway Internet (Modem del cloud)
#aws_internet_gateway = è il pezzo hardware virtuale di amazon che fa da ponte tra la rete privata e la rete pubblica mondiale
resource "aws_internet_gateway" "gw_k8s" {
	#attacchiamo questo modem alla nostra rete (VPC)
	#vpc_id = stiamo agganciando questo pezzo alla nostra rete esistente sfruttando l'ID
	vpc_id = aws_vpc.mia_rete_k8s.id
	tags = {
		Name = "igw-cluster-k8s"
	}
}

#7. --- Tabella di routing 
resource "aws_route_table" "rt_pubblica" {
	#creiamo la regola di traffico route
	#0.0.0.0/0 = significa qualsiasi indirizzo su Internet
	#"gateway_id = aws_internet_gateway.gw_k8s.id" = mandiamo il traffico verso il gateway internet creato nel blocco 6 
	vpc_id = aws_vpc.mia_rete_k8s.id 
	route {
		cidr_block = "0.0.0.0/0"
		gateway_id = aws_internet_gateway.gw_k8s.id
	}
	tags = {
		Name = "rt-pubblica-k8s"
	}
}


#8. --- Associazione tabella-sottorete
resource "aws_route_table_association" "rt_assoc_pubblica" {
	#applichiamo le regole della tabella di routing a questa specifica sottorete
	subnet_id	= aws_subnet.subnet_pubblica.id
	route_table_id	= aws_route_table.rt_pubblica.id
}
	

#9. --- Firewall (Security group)
resource "aws_security_group" "sg_k8s" {
	#a differenza della VPC, i security group richiedono obbligatoriamente un nome fisico e una descrizione.
	name	= "firewall-cluster-k8s"
	description	= "permette traffico SSH in entrata solo dal mio IP e tutto in uscita"
	#agganciamolo alla nostra rete creata nel blocco 4
	vpc_id	= aws_vpc.mia_rete_k8s.id
	#regole in entrata (ingress)
	ingress {
		description = "accesso SSH blindato (solo casa mia)"
		#from_port, to_port= è un range, scrivendo in entrambi 22 stiamo aprendo solo la porta 22 dedicata all'SSH
		#"protocol = tcp" = SSH viaggia sul protocollo di rete TCP
		#"cidr_block = [IP/32]" = è la blindatura. il /32 significa nessuna rete, solo ed esclusivamente quest'IP può accedere. Chiunque altro abbia un IP diverso vedrà il server di amazon spento o inesistente
		from_port	= 22
		to_port		= 22
		protocol	= "tcp"
		cidr_blocks	= [var.mio_ip_casa]
	}
	#regole in uscita (egress)
	egress {
		#from_port, to_port = 0 significa che copre tutte le porte possibili
		#"protocol = -1" = tutti i protocolli, non solo TCP (UDP, ICMP= per fare i ping) 
		from_port	= 0
		to_port		= 0
		protocol	= "-1"
		cidr_blocks	= ["0.0.0.0/0"]
	}
	tags = {
		Name = "sg-pubblico-k8s"
	}
}




#10. --- Il radar per il sistema operativo
#a differenza di resource, che crea cose nuove, data è un comando di sola lettura, interroga i database di Amazon per cercare qualcosa che esiste già
#"aws_ami" = Amazon Machine Image. è il termine tecnico per l'ISO
data "aws_ami" "ubuntu" {
	#"most_recent = true" = assicura che terraform usi sempre l'ultima patch di sicurezza rilasciata, ignorando le versioni vecchie
	#"owners = [...]" = è l'ID univoco e ufficiale di Canonical (azienda che programma ubuntu). In AWS chiunque può caricare immagini, mettendo quest'ID ci assicuriamo di non scaricare mai un sistema operativo contraffatto da un hacker
	most_recent	= true
	owners		= ["099720109477"] 
	#"values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-**]" = stiamo dicendo esattamente cosa cercare. Vogliamo "Jammy" (ubuntu 22.04) su architettura standard a 64 bit (amd64), ottimizzata per dischi veloci (hvm-ssd). L'asterisco finale è un jolly, in questo modo scaricherà qualsiasi data di rilascio purchè sia 22.04.
	filter {
		name = "name"
		values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
	}
}

#11. --- Chiave SSH su AWS
resource "aws_key_pair" "chiave_k8s" {
	#"key_name = "..." = nome etichetta che vedremo nell'interfaccia di Amazon
	key_name	= "chiave-cluster-k8s"
	#"public_key = file(...)" = invece di scrivere tutta la chiave in caratteri alfanumerici, la funzione file() legge in automatico il file .pub e lo inietta direttamente nel cloud
	public_key	= file("~/.ssh/k8s_key.pub")
}

#12. --- Il server (istanza EC2)
resource "aws_instance" "server_k8s" {
	#"ami = data.aws_ami.ubuntu.id" = invece di scrivere un codice a mano, diciamo a terraform di installare come sistema operativo quello che hai appena trovato con il radar nel blocco 10
	ami	= data.aws_ami.ubuntu.id
	#"instance_type = "t3.micro" = la taglia dell'hardware. t3.micro dà 2 vCPU e 1 gb di RAM 
	instance_type	= "t3.micro"
	#"subnet_id = aws_subnet.subnet_pubblica.id" = mettiamo questo server nella sottorete che abbiamo costruito nel blocco 5 
	subnet_id	= aws_subnet.subnet_pubblica.id
	#"vpc_security_group_ids  = [aws_security_group.sg_k8s.id]" = mettiamo il firewall per il nostro server che abbiamo creato nel blocco 9. Viene inserito nelle [] perchè un server può avere anche più di un firewall contemporaneamente
	vpc_security_group_ids	= [aws_security_group.sg_k8s.id]
	#"key_name = aws_key_pair.chiave_k8s.key_name" = inseriamo la chiave pubblica creata nel blocco 11. Solo chi possiede la chiave privata potrà entrare
	key_name	= aws_key_pair.chiave_k8s.key_name
	tags = {
		Name = "server-kubernetes-1"
	}
}

#13. --- Output dell'IP pubblico dell'EC2
#output = è il comando di terraform che estrae un'informazione e la stampa a schermo, nel nostro caso dal cloud
output "ip_del_server" {
	description = "L'indirizzo IP pubblico attuale dell'istanza EC2"
	#"value   = aws_instance.server_k8s.pubblic_ip" = aws_instance = è la risorsa, cercherà tra i server fisici e virtuali. .server_k8s = il nome che abbiamo assegnato nel blocco 12 al server. .public_ip = attributo che vogliamo estrarre. Amazon assegna tantissimi dati a un server (ad esempio: RAM, ID, ecc...)
	value	= aws_instance.server_k8s.public_ip
}
