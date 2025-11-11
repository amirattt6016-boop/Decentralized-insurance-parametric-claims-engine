;; Decentralized Insurance Parametric Claims Processor
;; Monitors weather oracle data, evaluates trigger conditions,
;; calculates payout amounts, and executes instant settlements

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-already-exists (err u103))
(define-constant err-invalid-data (err u104))
(define-constant err-insufficient-funds (err u105))
(define-constant err-policy-expired (err u106))
(define-constant err-already-claimed (err u107))
(define-constant err-conditions-not-met (err u108))

;; Data Variables
(define-data-var total-policies uint u0)
(define-data-var total-claims-paid uint u0)
(define-data-var total-premium-collected uint u0)
(define-data-var reserve-pool uint u0)

;; Data Maps
(define-map insurance-policies
  { policy-id: uint }
  {
    insurer: principal,
    policy-type: (string-ascii 50), ;; "crop", "flight", "weather", "catastrophe"
    coverage-amount: uint,
    premium-amount: uint,
    trigger-condition: (string-ascii 100),
    trigger-threshold: uint,
    payout-percentage: uint, ;; 0-100
    created-at: uint,
    expiry-at: uint,
    is-active: bool,
    total-purchased: uint
  }
)

(define-map policy-holders
  { policy-id: uint, holder: principal }
  {
    purchased-at: uint,
    premium-paid: uint,
    is-active: bool,
    claim-paid: bool,
    claim-amount: uint
  }
)

(define-map oracle-data
  { data-id: uint }
  {
    policy-type: (string-ascii 50),
    data-source: (string-ascii 100),
    data-value: uint,
    timestamp: uint,
    oracle-address: principal,
    is-validated: bool
  }
)

(define-map claims-registry
  { claim-id: uint }
  {
    policy-id: uint,
    holder: principal,
    trigger-data-id: uint,
    payout-amount: uint,
    claimed-at: uint,
    status: (string-ascii 20) ;; "pending", "approved", "paid"
  }
)

(define-map authorized-oracles
  { oracle: principal }
  { is-authorized: bool, data-submissions: uint }
)

(define-map insurer-pools
  { insurer: principal }
  { balance: uint, policies-created: uint }
)

;; Private Functions
(define-private (calculate-payout (coverage-amount uint) (payout-percentage uint))
  (/ (* coverage-amount payout-percentage) u100)
)

(define-private (check-trigger-condition (threshold uint) (actual-value uint) (policy-type (string-ascii 50)))
  ;; Simplified: returns true if actual-value exceeds threshold
  (>= actual-value threshold)
)

;; Read-only Functions
(define-read-only (get-policy (policy-id uint))
  (map-get? insurance-policies { policy-id: policy-id })
)

(define-read-only (get-policy-holder-info (policy-id uint) (holder principal))
  (map-get? policy-holders { policy-id: policy-id, holder: holder })
)

(define-read-only (get-oracle-data (data-id uint))
  (map-get? oracle-data { data-id: data-id })
)

(define-read-only (get-claim (claim-id uint))
  (map-get? claims-registry { claim-id: claim-id })
)

(define-read-only (get-reserve-pool)
  (ok (var-get reserve-pool))
)

(define-read-only (get-total-claims-paid)
  (ok (var-get total-claims-paid))
)

(define-read-only (is-authorized-oracle (oracle principal))
  (default-to false 
    (get is-authorized (map-get? authorized-oracles { oracle: oracle }))
  )
)

(define-read-only (get-insurer-pool (insurer principal))
  (default-to { balance: u0, policies-created: u0 }
    (map-get? insurer-pools { insurer: insurer })
  )
)

;; Public Functions - Policy Management
(define-public (create-policy
  (policy-type (string-ascii 50))
  (coverage-amount uint)
  (premium-amount uint)
  (trigger-condition (string-ascii 100))
  (trigger-threshold uint)
  (payout-percentage uint)
  (duration uint)
)
  (let
    (
      (policy-id (+ (var-get total-policies) u1))
    )
    (asserts! (> coverage-amount u0) err-invalid-data)
    (asserts! (> premium-amount u0) err-invalid-data)
    (asserts! (<= payout-percentage u100) err-invalid-data)
    (asserts! (> duration u0) err-invalid-data)
    
    (map-set insurance-policies
      { policy-id: policy-id }
      {
        insurer: tx-sender,
        policy-type: policy-type,
        coverage-amount: coverage-amount,
        premium-amount: premium-amount,
        trigger-condition: trigger-condition,
        trigger-threshold: trigger-threshold,
        payout-percentage: payout-percentage,
        created-at: stacks-block-height,
        expiry-at: (+ stacks-block-height duration),
        is-active: true,
        total-purchased: u0
      }
    )
    
    (var-set total-policies policy-id)
    (ok policy-id)
  )
)

(define-public (purchase-policy (policy-id uint))
  (let
    (
      (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) err-not-found))
      (premium (get premium-amount policy))
      (insurer (get insurer policy))
      (insurer-pool (get-insurer-pool insurer))
    )
    (asserts! (get is-active policy) err-invalid-data)
    (asserts! (>= (get expiry-at policy) stacks-block-height) err-policy-expired)
    
    ;; Transfer premium from buyer to contract
    (try! (stx-transfer? premium tx-sender (as-contract tx-sender)))
    
    ;; Record policy holder
    (map-set policy-holders
      { policy-id: policy-id, holder: tx-sender }
      {
        purchased-at: stacks-block-height,
        premium-paid: premium,
        is-active: true,
        claim-paid: false,
        claim-amount: u0
      }
    )
    
    ;; Update insurer pool
    (map-set insurer-pools
      { insurer: insurer }
      { balance: (+ (get balance insurer-pool) premium),
        policies-created: (get policies-created insurer-pool) }
    )
    
    ;; Update policy stats
    (map-set insurance-policies
      { policy-id: policy-id }
      (merge policy {
        total-purchased: (+ (get total-purchased policy) u1)
      })
    )
    
    (var-set total-premium-collected (+ (var-get total-premium-collected) premium))
    (var-set reserve-pool (+ (var-get reserve-pool) premium))
    (ok true)
  )
)

(define-public (submit-oracle-data
  (policy-type (string-ascii 50))
  (data-source (string-ascii 100))
  (data-value uint)
)
  (let
    (
      (data-id (+ (var-get total-claims-paid) u1))
    )
    (asserts! (is-authorized-oracle tx-sender) err-unauthorized)
    
    (map-set oracle-data
      { data-id: data-id }
      {
        policy-type: policy-type,
        data-source: data-source,
        data-value: data-value,
        timestamp: stacks-block-height,
        oracle-address: tx-sender,
        is-validated: true
      }
    )
    
    (ok data-id)
  )
)

(define-public (evaluate-and-claim
  (policy-id uint)
  (oracle-data-id uint)
)
  (let
    (
      (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) err-not-found))
      (holder-info (unwrap! (map-get? policy-holders { policy-id: policy-id, holder: tx-sender }) err-not-found))
      (oracle-info (unwrap! (map-get? oracle-data { data-id: oracle-data-id }) err-not-found))
      (coverage-amount (get coverage-amount policy))
      (payout-percentage (get payout-percentage policy))
      (payout-amount (calculate-payout coverage-amount payout-percentage))
      (claim-id (+ (var-get total-claims-paid) u1))
    )
    (asserts! (get is-active holder-info) err-invalid-data)
    (asserts! (not (get claim-paid holder-info)) err-already-claimed)
    (asserts! (get is-validated oracle-info) err-invalid-data)
    
    ;; Check if trigger condition is met
    (asserts! 
      (check-trigger-condition 
        (get trigger-threshold policy) 
        (get data-value oracle-info)
        (get policy-type policy)
      )
      err-conditions-not-met
    )
    
    (asserts! (>= (var-get reserve-pool) payout-amount) err-insufficient-funds)
    
    ;; Record claim
    (map-set claims-registry
      { claim-id: claim-id }
      {
        policy-id: policy-id,
        holder: tx-sender,
        trigger-data-id: oracle-data-id,
        payout-amount: payout-amount,
        claimed-at: stacks-block-height,
        status: "approved"
      }
    )
    
    ;; Execute payout
    (try! (as-contract (stx-transfer? payout-amount tx-sender tx-sender)))
    
    ;; Update holder info
    (map-set policy-holders
      { policy-id: policy-id, holder: tx-sender }
      (merge holder-info {
        claim-paid: true,
        claim-amount: payout-amount
      })
    )
    
    ;; Update reserve pool
    (var-set reserve-pool (- (var-get reserve-pool) payout-amount))
    (var-set total-claims-paid (+ (var-get total-claims-paid) payout-amount))
    
    (ok claim-id)
  )
)

(define-public (cancel-policy (policy-id uint))
  (let
    (
      (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) err-not-found))
    )
    (asserts! (is-eq tx-sender (get insurer policy)) err-unauthorized)
    (map-set insurance-policies
      { policy-id: policy-id }
      (merge policy { is-active: false })
    )
    (ok true)
  )
)

(define-public (deposit-to-pool (amount uint))
  (let
    (
      (insurer-pool (get-insurer-pool tx-sender))
    )
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set insurer-pools
      { insurer: tx-sender }
      { balance: (+ (get balance insurer-pool) amount),
        policies-created: (get policies-created insurer-pool) }
    )
    (var-set reserve-pool (+ (var-get reserve-pool) amount))
    (ok true)
  )
)

(define-public (withdraw-from-pool (amount uint))
  (let
    (
      (insurer-pool (get-insurer-pool tx-sender))
      (balance (get balance insurer-pool))
    )
    (asserts! (>= balance amount) err-insufficient-funds)
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    (map-set insurer-pools
      { insurer: tx-sender }
      { balance: (- balance amount),
        policies-created: (get policies-created insurer-pool) }
    )
    (var-set reserve-pool (- (var-get reserve-pool) amount))
    (ok true)
  )
)

;; Admin Functions
(define-public (authorize-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set authorized-oracles
      { oracle: oracle }
      { is-authorized: true, data-submissions: u0 }
    )
    (ok true)
  )
)

(define-public (revoke-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set authorized-oracles
      { oracle: oracle }
      { is-authorized: false, data-submissions: u0 }
    )
    (ok true)
  )
)

;; title: parametric-claims-processor
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

