CREATE TABLE IF NOT EXISTS menu
(
    id          bigserial NOT NULL,
    code        character varying(6) COLLATE pg_catalog."default" NOT NULL,
    parent      integer DEFAULT 0,
    "level"     integer DEFAULT 0,
    "order"     integer DEFAULT 0,
    "module"    character varying(50) COLLATE pg_catalog."default",
    "name"      character varying(50) COLLATE pg_catalog."default",
    "url"           character varying(100) COLLATE pg_catalog."default",
    "description"   character varying(100) COLLATE pg_catalog."default",
    "label"         character varying(100) COLLATE pg_catalog."default",
    icon            character varying(100) COLLATE pg_catalog."default",
	
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
	
    CONSTRAINT menu_pk PRIMARY KEY (id)
);


CREATE TABLE IF NOT EXISTS profile
(
    id 		    bigserial NOT NULL,
    "name" 	    character varying COLLATE pg_catalog."default",
    isactive 	boolean DEFAULT true,
    inactivity	integer DEFAULT 60,
	
    created_at 	timestamp with time zone,
    updated_at 	timestamp with time zone,
	
    CONSTRAINT perfil_pk PRIMARY KEY (id)
);

ALTER TABLE IF EXISTS public.profile
    ADD CONSTRAINT uniq_name UNIQUE (name);


CREATE TABLE IF NOT EXISTS access
(
    id 		    bigserial NOT NULL,
    profile_id 	integer,
    menu_id 	integer,
	
    view      	boolean DEFAULT false,
    "create"  	boolean DEFAULT false,
    edit  	    boolean DEFAULT false,
    "delete"  	boolean DEFAULT false,
    report  	boolean DEFAULT false,
    "execute"  	boolean DEFAULT false,
    list 	    boolean DEFAULT false,
	
    created_at 	timestamp with time zone,
    updated_at 	timestamp with time zone,
	
    CONSTRAINT access_pk PRIMARY KEY (id),
    CONSTRAINT access_menu_fk FOREIGN KEY (menu_id)
        REFERENCES menu (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT access_profile_fk FOREIGN KEY (profile_id)
        REFERENCES profile(id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
);



CREATE TABLE IF NOT EXISTS users
(
    id 		bigserial NOT NULL,
	
    "name" 	character varying(100) COLLATE pg_catalog."default" NOT NULL,
    surname character varying(100) COLLATE pg_catalog."default",
    email 	character varying(100) COLLATE pg_catalog."default" NOT NULL,
    phone 	character varying(20) COLLATE pg_catalog."default",
	
    login_user 	character varying(30) COLLATE pg_catalog."default" NOT NULL,
    "password" 	character varying(255) COLLATE pg_catalog."default" NOT NULL,
    avatar 	    character varying(1000) COLLATE pg_catalog."default",
    type_user 	integer DEFAULT 1,
    isactive 	boolean DEFAULT true,
    islogin     boolean DEFAULT false,

    profile_id integer,
	
    created_at timestamp(0) without time zone,
    updated_at timestamp(0) without time zone,
    email_verified_at timestamp(0) without time zone,
    user_verified_at timestamp(0) without time zone,
	
    CONSTRAINT user_pkey PRIMARY KEY (id),
    CONSTRAINT user_unique UNIQUE (login_user),
    CONSTRAINT user_profile FOREIGN KEY (profile_id)
        REFERENCES profile (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION	
);





INSERT INTO public.menu (code,parent,"module","name",description,url,icon,created_at,updated_at,"order","label","level") VALUES
	 ('HOME01',0,'HOME','home','Home','/home','fa fa-home',NULL,NULL,1,NULL,0),
	 ('DEMO',0,'DEMO','Demo','Demo','demo/home','fa fa-sitemap',NULL,NULL,100,'Novedades',0),
	 ('DEMO01',1,NULL,'dashboard2','Dashboard 2','demo/dashboard2',NULL,NULL,NULL,101,NULL,1),
	 ('DEMO04',1,NULL,'tabs-accordions','tabs-acoordions','ui/tabs-accordions','fa fa-sitemap',NULL,NULL,102,NULL,1),
	 ('DEMO02',1,NULL,'dashboard1','Dashboard 1','demo/home',NULL,NULL,NULL,103,NULL,1),
	 ('DEMO05',6,NULL,'DEMO3.1','DEMO3.1','DEMO3.1',NULL,NULL,NULL,104,NULL,2),
	 ('CONF',0,'CONFIGURACION','Configuracion','Configuracion','config/home','fa fa-cog',NULL,NULL,50,NULL,0),
	 ('CONF01',5,NULL,'allProfiles','Perfiles','config/allProfiles',NULL,NULL,NULL,51,NULL,1),
	 ('CONF02',5,NULL,'allMenus','Menus','config/allMenus',NULL,NULL,NULL,52,NULL,1),
	 ('DEMO03',1,NULL,'dashboard4','Dashboard 4','demo/dashboard4',NULL,NULL,NULL,108,NULL,1);
INSERT INTO public.menu (code,parent,"module","name",description,url,icon,created_at,updated_at,"order","label","level") VALUES
	 ('DEMO07',11,NULL,'DEMO 3.1.1','DEMO 3.1.1','DEMO 3.1.1',NULL,NULL,NULL,105,NULL,3),
	 ('DEMO06',6,NULL,'DEMO3.2','DEMO3.2','DEMO3.2',NULL,NULL,NULL,106,NULL,2),
	 ('DEMO08',12,NULL,'DEMO 3.2.1','DEMO 3.2.1','DEMO 3.2.1',NULL,NULL,NULL,107,NULL,4);




INSERT INTO public.profile ("name",isactive,inactivity,created_at,updated_at) VALUES
	 ('SISTEMAS',true,0,'2025-01-07 15:52:24-05','2025-03-03 19:27:40-05'),
	 ('SISTEMAS_CLON',true,0,'2025-03-02 18:10:13-05','2025-03-04 22:56:08-05');


INSERT INTO public."access" (profile_id,menu_id,"view","create",edit,"delete",report,"execute",list,created_at,updated_at) VALUES
	 (1,1,true,true,true,true,false,true,true,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,2,true,true,true,true,false,true,true,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,3,true,true,true,true,false,false,true,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,6,true,true,true,true,true,true,true,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,11,false,false,false,false,false,true,true,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,13,false,false,false,false,true,true,false,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,15,false,false,false,false,false,true,false,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,12,false,false,false,false,true,true,false,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,7,false,false,false,false,false,true,true,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05');
	 (1,4,true,true,true,true,false,true,true,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,5,true,true,true,true,true,true,true,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,10,true,true,true,true,true,true,true,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05'),
	 (1,14,false,false,false,false,false,true,false,'2025-03-03 19:27:40-05','2025-03-03 19:27:40-05');




INSERT INTO public.users ("name",surname,email,phone,login_user,"password",avatar,type_user,isactive,islogin,profile_id,created_at,updated_at,deleted_at,email_verified_at,user_verified_at) VALUES
	 ('Leonardo','Agila','leo@gmail.com',NULL,'LAGILA','$2y$12$J.AruQWawVHQ7a.rzaDANuGg2KFUFtNaT9lAWiOYBGe/secY.Mr0y',NULL,1,true,true,1,'2025-03-02 10:33:56','2025-03-02 10:33:56',NULL,NULL,'2025-03-04 21:53:14'),
	 ('leo','agila','leo9@gmail.com',NULL,'LAGILA2','$2y$12$J.AruQWawVHQ7a.rzaDANuGg2KFUFtNaT9lAWiOYBGe/secY.Mr0y',NULL,1,true,false,4,'2024-12-02 02:18:15','2024-12-02 02:18:15',NULL,NULL,'2025-03-03 17:53:52');





CREATE TABLE IF NOT EXISTS departamento
(
    id          bigserial NOT NULL,
    nombre      character varying(50) COLLATE pg_catalog."default",
    activo 	boolean DEFAULT true,	
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
	
    CONSTRAINT departamento_pk PRIMARY KEY (id),
    CONSTRAINT uk_nombre_departamento UNIQUE (nombre);
);



CREATE TABLE IF NOT EXISTS reporteexterno
(
    id          bigserial NOT NULL,
    nombre      character varying(50) COLLATE pg_catalog."default",
    descripcion character varying(500) COLLATE pg_catalog."default",
    url      character varying(500) COLLATE pg_catalog."default",
    activo 	boolean DEFAULT true,	

    departamento_id integer,

    created_at timestamp with time zone,
    updated_at timestamp with time zone,

    CONSTRAINT pk_reporteexterno PRIMARY KEY (id),
    CONSTRAINT uk_nombre_reporteexterno UNIQUE (nombre),
    CONSTRAINT fk_reporteexterno_departamento FOREIGN KEY (departamento_id)
);


CREATE TABLE IF NOT EXISTS public.users_reporteexterno
(
    id bigserial NOT NULL,
    users_id bigint,
    reporteexterno_id bigint,
    created_at time with time zone,
    updated_at time with time zone,
    view_at time with time zone,
    CONSTRAINT pk_usuario_reporteexterno PRIMARY KEY (id),
    CONSTRAINT fk_reporteexterno_id FOREIGN KEY (reporteexterno_id)
        REFERENCES public.reporteexterno (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION,
    CONSTRAINT fk_users_id FOREIGN KEY (users_id)
        REFERENCES public.users (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
);


CREATE TABLE IF NOT EXISTS archivo
(
    id        bigserial NOT NULL,
    padre     integer DEFAULT 0,
    orden     integer DEFAULT 0,
    nivel     integer DEFAULT 0,
    tipo      character varying(30) COLLATE pg_catalog."default",
    nombre    character varying(100) COLLATE pg_catalog."default",
    url       character varying(200) COLLATE pg_catalog."default",
    descripcion character varying(200) COLLATE pg_catalog."default",
    modulo    character varying(100) COLLATE pg_catalog."default",
    icono 	character varying(100) COLLATE pg_catalog."default",
    activo 	boolean DEFAULT true,
    escarpeta	boolean DEFAULT true,	
    color	character varying(15) COLLATE pg_catalog."default",
    created_at 	timestamp with time zone,
    updated_at 	timestamp with time zone,

    CONSTRAINT archivo_pk PRIMARY KEY (id)
);
