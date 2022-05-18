DROP TABLE IF EXISTS public.shipping;

--shipping
CREATE TABLE public.shipping(
   ID serial,
   shippingid                         BIGINT,
   saleid                             BIGINT,
   orderid                            BIGINT,
   clientid                           BIGINT,
   payment_amount                          NUMERIC(14,2),
   state_datetime                    TIMESTAMP,
   productid                          BIGINT,
   description                       text,
   vendorid                           BIGINT,
   namecategory                      text,
   base_country                      text,
   status                            text,
   state                             text,
   shipping_plan_datetime            TIMESTAMP,
   hours_to_plan_shipping           NUMERIC(14,2),
   shipping_transfer_description     text,
   shipping_transfer_rate           NUMERIC(14,3),
   shipping_country                  text,
   shipping_country_base_rate       NUMERIC(14,3),
   vendor_agreement_description      text,
   PRIMARY KEY (ID)
);
CREATE INDEX shippingid ON public.shipping (shippingid);
COMMENT ON COLUMN public.shipping.shippingid is 'id of shipping of sale';


-- 1 create public.shipping_country_rates ++
DROP TABLE IF EXISTS public.shipping_country_rates;
CREATE TABLE public.shipping_country_rates(
shipping_country_id serial,
shipping_country TEXT,
shipping_country_base_rate NUMERIC(14,3),
PRIMARY KEY (shipping_country_id)
);

INSERT INTO public.shipping_country_rates 
(shipping_country, shipping_country_base_rate)
SELECT DISTINCT shipping_country, shipping_country_base_rate
FROM public.shipping;

--SELECT * FROM public.shipping_country_rates;


-- 2 create public.shipping_agreement ++
DROP TABLE IF EXISTS public.shipping_agreement;
CREATE TABLE public.shipping_agreement(
agreementid bigint,
agreement_number text,
agreement_rate NUMERIC(14,3),
agreement_commission NUMERIC(14,3),
PRIMARY KEY (agreementid)
);

INSERT INTO public.shipping_agreement
(agreementid, agreement_number, agreement_rate, agreement_commission)
SELECT split[1]::bigint agreementid, 
	   split[2]::text agreement_number, 
	   split[3]::NUMERIC(14,3) agreement_rate, 
	   split[4]::NUMERIC(14,3) agreement_commission
FROM 
(SELECT DISTINCT regexp_split_to_array(vendor_agreement_description , ':') split
FROM public.shipping) sh;

--SELECT * FROM shipping_agreement WHERE agreementid = 32;


-- 3 create public.shipping_transfer ++
DROP TABLE IF EXISTS public.shipping_transfer;
CREATE TABLE public.shipping_transfer(
transfer_type_id serial,
transfer_type text,
transfer_model text,
shipping_transfer_rate NUMERIC(14,3),
PRIMARY KEY (transfer_type_id)
);

INSERT INTO public.shipping_transfer
(transfer_type, transfer_model, shipping_transfer_rate)
SELECT transfer[1] transfer_type,
	   transfer[2] transfer_model,
	   shipping_transfer_rate
FROM (
SELECT DISTINCT regexp_split_to_array(shipping_transfer_description , ':') transfer, shipping_transfer_rate
FROM public.shipping) sh;

--SELECT * FROM public.shipping_transfer;


-- 4 create public.shipping_info ++
DROP TABLE IF EXISTS public.shipping_info;
CREATE TABLE public.shipping_info(
shippingid BIGINT,
vendorid BIGINT,
payment_amount NUMERIC(14,2),
shipping_plan_datetime TIMESTAMP,
transfer_type_id BIGINT,
shipping_country_id BIGINT,
agreementid BIGINT,
PRIMARY KEY (shippingid),
FOREIGN KEY (transfer_type_id) REFERENCES public.shipping_transfer(transfer_type_id) ON UPDATE CASCADE,
FOREIGN KEY (shipping_country_id) REFERENCES public.shipping_country_rates(shipping_country_id) ON UPDATE CASCADE,
FOREIGN KEY (agreementid) REFERENCES public.shipping_agreement(agreementid) ON UPDATE CASCADE
);

INSERT INTO public.shipping_info
(shippingid,
vendorid,
payment_amount,
shipping_plan_datetime,
transfer_type_id,
shipping_country_id,
agreementid)
SELECT DISTINCT sh.shippingid, sh.vendorid, sh.payment_amount, sh.shipping_plan_datetime,  
	   tr.transfer_type_id::BIGINT,
	   cr.shipping_country_id::BIGINT,
	   agr.agreementid 
FROM public.shipping sh
LEFT JOIN public.shipping_transfer tr ON concat(transfer_type, ':', transfer_model) = sh.shipping_transfer_description
LEFT JOIN public.shipping_country_rates cr ON cr.shipping_country = sh.shipping_country
LEFT JOIN public.shipping_agreement agr ON agreementid = (regexp_split_to_array(sh.vendor_agreement_description , ':'))[1]::bigint -- зачем, если в shipping всё есть?
;

--SELECT * FROM public.shipping_info;


-- 5 shipping_status ++
DROP TABLE IF EXISTS public.shipping_status;
CREATE TABLE public.shipping_status(
shippingid BIGINT, 
status text, 
state text,
shipping_start_fact_datetime TIMESTAMP,
shipping_end_fact_datetime TIMESTAMP,
PRIMARY KEY (shippingid)
);

WITH sh AS (
SELECT shippingid, status, state, state_datetime AS max_dt, 
	   ROW_NUMBER() OVER (PARTITION BY shippingid ORDER BY state_datetime desc) rn
FROM public.shipping)
INSERT INTO public.shipping_status
(shippingid, status, state, shipping_start_fact_datetime, shipping_end_fact_datetime)
SELECT sh.shippingid, sh.status, sh.state,
	   shb.state_datetime AS shipping_start_fact_datetime,
	   shr.state_datetime AS shipping_end_fact_datetime
FROM sh
LEFT JOIN public.shipping shr ON shr.shippingid = sh.shippingid AND shr.state = 'recieved'
LEFT JOIN public.shipping shb ON shb.shippingid = sh.shippingid AND shb.state = 'booked'
WHERE sh.rn = 1;

--SELECT * FROM public.shipping_status ORDER BY shippingid;


-- 6 shipping_datamart ++
CREATE VIEW shipping_datamart AS ( 
SELECT inf.shippingid, inf.vendorid, tr.transfer_type,
       date_part('day', shipping_end_fact_datetime - shipping_start_fact_datetime) AS full_day_at_shipping, 
       CASE WHEN shipping_end_fact_datetime > shipping_start_fact_datetime THEN 1 ELSE 0 END AS is_delay,
       CASE WHEN st.status = 'finished' THEN 1 ELSE 0 END AS is_shipping_finish, 
	   CASE WHEN shipping_end_fact_datetime > shipping_start_fact_datetime THEN date_part('day', shipping_end_fact_datetime - shipping_start_fact_datetime) ELSE 0 END AS delay_day_at_shipping,
	   inf.payment_amount,
	   payment_amount * (shipping_country_base_rate + agreement_rate + shipping_transfer_rate) AS vat,
	   payment_amount * agreement_commission AS profit
FROM public.shipping_info inf
LEFT JOIN public.shipping_status st ON st.shippingid = inf.shippingid
LEFT JOIN public.shipping_transfer tr ON inf.transfer_type_id = tr.transfer_type_id
LEFT JOIN public.shipping_country_rates cr ON cr.shipping_country_id = inf.shipping_country_id
LEFT JOIN public.shipping_agreement agr ON agr.agreementid = inf.agreementid)
