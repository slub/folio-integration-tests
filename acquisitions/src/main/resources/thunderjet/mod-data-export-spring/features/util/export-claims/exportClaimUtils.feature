@ignore
Feature: Init Data for Claims Export

  Background:
    * print karate.info.scenarioName
    * url baseUrl

    # Replace these 2 lines to remove date and time constraints, but match with file ids
    * def interchangeHeaderRegexTemplte = "UNB\\+UNOC:3\\+LIB-EDI-CODE:091\\+VENDOR-EDI-CODE:091\\+\\d{6}:\\d{4}\\+{fileId}'"
    * def interchangeHeaderSampleTemplate = "UNB+UNOC:3+LIB-EDI-CODE:091+VENDOR-EDI-CODE:091+150125:1249+{fileId}'"
    * def orderDateRegex = "DTM\\+137:\\d{8}:102'"
    * def orderDateSample = "DTM+137:20250115:102'"

  @InitData
  Scenario: initData
    # parameters: orgId, orgCode, accountNo,
    #             configId, configName, transMeth, fileFormat, ftpFormat,
    #             poNumber, poLineNumber, pieceId, fundId, currentDate

    # 1. Create organization
    * def accounts = [{ name: "#(orgCode)_ACC", accountNo: "#(accountNo)", accountStatus: "Active" }]
    * table orgData
      | id    | code    | name    | accounts | isVendor |
      | orgId | orgCode | orgCode | accounts | true     |
    * callonce createOrganization orgData

    # 2. Create organization integration details
    # The Claims config must select the PO line's acquisition method (order-line.json uses Approval Plan),
    # because mod-orders routes claimed pieces through GET /data-export-spring/effective-configs
    * def claimsAcqMethods = ["#(globalApprovalPlanAcqMethodId)"]
    * table orgIntegrationDetails
      | configId | configName | vendorId | transmissionMethod | fileFormat | ftpFormat | accountNoList    | defaultAcquisitionMethods |
      | configId | configName | orgId    | transMeth          | fileFormat | ftpFormat | ["#(accountNo)"] | claimsAcqMethods          |
    * callonce createIntegrationDetails orgIntegrationDetails

    # 3. Create order with order line and open order
    * def orderId = call uuid
    * def orderData = karate.read('classpath:thunderjet/mod-data-export-spring/features/samples/export-claims/order.json')
    Given path '/orders/composite-orders'
    And request orderData
    When method POST
    Then status 201

    * def poLineId = call uuid
    * def poLineData = karate.read('classpath:thunderjet/mod-data-export-spring/features/samples/export-claims/order-line.json')
    Given path '/orders/order-lines'
    And request poLineData
    When method POST
    Then status 201

    * def v = callonce openOrder { orderId: '#(orderId)' }

    # 4. Create title and piece
    * def titleId = call uuid
    * def titleData = karate.read('classpath:thunderjet/mod-data-export-spring/features/samples/export-claims/title.json')
    Given path '/orders/titles'
    And request titleData
    When method POST
    Then status 201

    * def pieceData = karate.read('classpath:thunderjet/mod-data-export-spring/features/samples/export-claims/piece.json')
    Given path '/orders/pieces'
    And request pieceData
    When method POST
    Then status 201


  @VerifyFileContentCsv
  Scenario: verifyFileContentCsv
    # parameters: jobId, _poLineNumber, _currentDate

    * def fileLineSeparator = '\n'
    * def systemLineSeparator = java.lang.System.lineSeparator()
    * table replacements
      | regex            | newString     |
      | '{poLineNumber}' | _poLineNumber |
      | '{currentDate}'  | _currentDate  |
    * def expectedCsvFile = karate.readAsString('classpath:thunderjet/mod-data-export-spring/features/samples/export-claims/claims.csv')
    * def expectedCsv = replaceRegex(expectedCsvFile, replacements)
    * def expectedCsv = convertStringToLines(expectedCsv, systemLineSeparator)

    Given path 'data-export-spring/jobs', jobId, 'download'
    When method GET
    Then status 200
    And string actualCsvFile = response
    * def actualCsv = replaceRegex(actualCsvFile, replacements)
    * def actualCsv = convertStringToLines(actualCsv, fileLineSeparator)
    * match expectedCsv == actualCsv


  @VerifyFileContentEdi
  Scenario: verifyFileContentEdi
    # parameters: jobId, _jobName, _poNumber, _poLineNumber

    * def fileLineSeparator = '\n'
    * def systemLineSeparator = java.lang.System.lineSeparator()

    # Get correct regex pattern and sample for interchange header with actual file id (job name)
    * table interchangeReplacements
      | regex      | newString |
      | '{fileId}' | _jobName  |
    * def interchangeHeaderRegex = replaceRegex(interchangeHeaderRegexTemplte, interchangeReplacements)
    * def interchangeHeaderSample = replaceRegex(interchangeHeaderSampleTemplate, interchangeReplacements)
    * table replacements
      | regex                  | newString               |
      | '{fileId}'             | _jobName                |
      | '{poNumber}'           | _poNumber               |
      | '{poLineNumber}'       | _poLineNumber           |
      | interchangeHeaderRegex | interchangeHeaderSample |
      | orderDateRegex         | orderDateSample         |
    * def expectedEdiFile = karate.readAsString('classpath:thunderjet/mod-data-export-spring/features/samples/export-claims/claims.edi')
    * def expectedEdi = replaceRegex(expectedEdiFile, replacements)
    * def expectedEdi = convertStringToLines(expectedEdi, systemLineSeparator)

    Given path 'data-export-spring/jobs', jobId, 'download'
    When method GET
    Then status 200
    And string actualEdiFile = response
    * def actualEdi = replaceRegex(actualEdiFile, replacements)
    * def actualEdi = convertStringToLines(actualEdi, fileLineSeparator)
    * match expectedEdi == actualEdi


  @CreatePiecesForPoLine
  Scenario: createPiecesForPoLine
    # parameters: _poLineNumber, _pieceIds

    # 1. Get poLine by poLineNumber
    Given path 'orders/order-lines'
    And param query = 'poLineNumber=' + _poLineNumber
    When method GET
    Then status 200
    And match response.totalRecords == 1
    * def poLineId = response.poLines[0].id

    # 2. Get title by poLineId
    Given path 'orders/titles'
    And param query = 'poLineId=' + poLineId
    When method GET
    Then status 200
    And match response.totalRecords == 1
    * def titleId = response.titles[0].id

    # 3. Create 249 pieces for the poLine
    * def pieceIdsTable = karate.map(_pieceIds, p => { return { pieceId: p, poLineId: poLineId, titleId: titleId } })
    * def v = call createPiece pieceIdsTable

    # 4. Set pieces status to Late
    * def v = call updatePiecesBatchStatus { pieceIds: "#(_pieceIds)", receivingStatus: 'Late' }

  @CreateLatePieceForVendor
  Scenario: createLatePieceForVendor
    # parameters: orgId, poNumber, poLineNumber, acqMethodId, pieceId, currentDate, claimSequenceId (optional)
    # Creates an open order for an existing vendor with one PO line using the given acquisition method and one Late piece.
    # With claimSequenceId the PO line is claimed by that claim sequence

    * def orderId = call uuid
    * def orderData = karate.read('classpath:thunderjet/mod-data-export-spring/features/samples/export-claims/order.json')
    Given path '/orders/composite-orders'
    And request orderData
    When method POST
    Then status 201

    * def poLineId = call uuid
    * def poLineData = karate.read('classpath:thunderjet/mod-data-export-spring/features/samples/export-claims/order-line.json')
    * set poLineData.acquisitionMethod = acqMethodId
    * def claimSequenceId = karate.get('claimSequenceId', null)
    * if (claimSequenceId != null) karate.set('poLineData', '$.claimSequenceId', claimSequenceId)
    Given path '/orders/order-lines'
    And request poLineData
    When method POST
    Then status 201

    * def v = call openOrder { orderId: '#(orderId)' }

    * def titleId = call uuid
    * def titleData = karate.read('classpath:thunderjet/mod-data-export-spring/features/samples/export-claims/title.json')
    Given path '/orders/titles'
    And request titleData
    When method POST
    Then status 201

    * def pieceData = karate.read('classpath:thunderjet/mod-data-export-spring/features/samples/export-claims/piece.json')
    Given path '/orders/pieces'
    And request pieceData
    When method POST
    Then status 201


  @CreateClaimSequence
  Scenario: createClaimSequence
    # parameters: sequenceId, sequenceName, stages, afterLastStage (optional), isActive (optional)
    * def afterLastStage = karate.get('afterLastStage', null)
    * def isActive = karate.get('isActive', null)
    Given path 'orders-storage/claim-sequences'
    And request { id: '#(sequenceId)', name: '#(sequenceName)', stages: '#(stages)', afterLastStage: '##(afterLastStage)', isActive: '##(isActive)' }
    When method POST
    Then status 201


  @ExpireClaim
  Scenario: expireClaim
    # parameters: pieceId
    # Simulates the passing of the claim interval: moves statusUpdatedDate of a 'Claim sent' piece into the past
    # (claimingInterval untouched) and runs the claiming timer, which sets the piece back to Late
    Given path 'orders/pieces', pieceId
    When method GET
    Then status 200
    And match response.receivingStatus == 'Claim sent'
    * def piece = response
    * set piece.statusUpdatedDate = '2024-01-23T12:50:03.156+00:00'
    Given path 'orders/pieces', pieceId
    And request piece
    When method PUT
    Then status 204

    Given path 'orders-storage/claiming/process'
    When method POST
    Then status 200

    * configure retry = { count: 10, interval: 3000 }
    Given path 'orders/pieces', pieceId
    And retry until response.receivingStatus == 'Late'
    When method GET
    Then status 200


  @VerifyPieceClaim
  Scenario: verifyPieceClaim
    # parameters: pieceId, receivingStatus, claimSequenceId, stage, interval
    Given path 'orders/pieces', pieceId
    When method GET
    Then status 200
    And match response.receivingStatus == receivingStatus
    And match response.claim.sequence == { id: '#(claimSequenceId)', stage: '#(stage)' }
    And match response.claimingInterval == interval


  @GetClaimsJobsOfConfig
  Scenario: getClaimsJobsOfConfig
    # parameters: configId, expectedCount
    # Waits until the Claims export config has exactly expectedCount jobs and returns them as 'jobs'
    * def ofConfig =
      """
      function(jobRecords) {
        return karate.filter(jobRecords, function(job) {
          return job.exportTypeSpecificParameters.vendorEdiOrdersExportConfig.exportConfigId == configId;
        });
      }
      """
    * configure retry = { count: 10, interval: 3000 }
    Given path 'data-export-spring/jobs'
    And param query = '(type==CLAIMS)'
    And param limit = 1000
    And retry until ofConfig(response.jobRecords).length == expectedCount
    When method GET
    Then status 200
    * def jobs = ofConfig(response.jobRecords)
