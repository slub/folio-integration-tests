@parallel=false
# POST /orders/pieces/claim and PUT /orders/pieces-batch/status claim a piece whose PO line has a claim sequence
# at the next stage of that sequence: piece.claim.sequence = { id, stage }, claimingInterval = stage interval.
# A MANUAL stage creates no export job, an INTEGRATION stage uses only the vendor's Claims configs with the
# stage's transmission method. After the last stage, STOP (default) rejects the claim, REPEAT_LAST repeats the last stage.
# The claiming timer is simulated by moving statusUpdatedDate into the past and running orders-storage/claiming/process.
Feature: Claims export by claim sequence

  Background:
    * print karate.info.scenarioName
    * url baseUrl

    * callonce login testUser
    * def okapitokenUser = okapitoken
    * def headersUser = { 'Content-Type': 'application/json', 'x-okapi-token': '#(okapitokenUser)', 'Accept': '*/*', 'x-okapi-tenant': '#(testTenant)' }
    * configure headers = headersUser

    * def createLatePiece = read('this:util/export-claims/exportClaimUtils.feature@CreateLatePieceForVendor')
    * def createClaimSequence = read('this:util/export-claims/exportClaimUtils.feature@CreateClaimSequence')
    * def expireClaim = read('this:util/export-claims/exportClaimUtils.feature@ExpireClaim')
    * def verifyPieceClaim = read('this:util/export-claims/exportClaimUtils.feature@VerifyPieceClaim')
    * def getJobsOfConfig = read('this:util/export-claims/exportClaimUtils.feature@GetClaimsJobsOfConfig')
    * def currentDate = callonce getCurrentDate

    * def resultOf = function(claimingResults, pieceId) { return karate.filter(claimingResults.claimingPieceResults, function(r) { return r.pieceId == pieceId; })[0]; }
    * def claimPieceIdsOf = function(job) { return job.exportTypeSpecificParameters.vendorEdiOrdersExportConfig.claimPieceIds; }
    * def errorCodesOf = function(errors) { return karate.map(errors.errors, function(e) { return e.code; }); }


  @Positive
  Scenario: A piece is claimed stage by stage (manual, File download, FTP) until the sequence stops
    # 1. Vendor with a File download and an FTP Claims config, both for every acquisition method
    * def orgId = call uuid
    * def configFileId = call uuid
    * def configFtpId = call uuid
    * def seqId = call uuid
    * def pieceId = call uuid
    * def otherPieceId = call uuid
    * def v = call createOrganization { id: '#(orgId)', code: 'ORG_SEQ_LADDER', name: 'ORG_SEQ_LADDER', isVendor: true }
    * table configs
      | configId     | configName          | vendorId | transmissionMethod | fileFormat | defaultAcquisitionMethods |
      | configFileId | "SEQ_LADDER_FILE"   | orgId    | "File download"    | "CSV"      | []                        |
      | configFtpId  | "SEQ_LADDER_FTP"    | orgId    | "FTP"              | "CSV"      | []                        |
    * def v = call createIntegrationDetails configs

    # 2. Claim sequence without afterLastStage: the default is STOP
    * def stages =
      """
      [
        { name: '1st claim (phone)', deliveryType: 'MANUAL', interval: 3 },
        { name: '2nd claim (file)', deliveryType: 'INTEGRATION', transmissionMethod: 'File download', interval: 5 },
        { name: '3rd claim (FTP)', deliveryType: 'INTEGRATION', transmissionMethod: 'FTP', interval: 7 }
      ]
      """
    * def v = call createClaimSequence { sequenceId: '#(seqId)', sequenceName: 'SEQ_LADDER', stages: '#(stages)' }
    Given path 'orders-storage/claim-sequences', seqId
    When method GET
    Then status 200
    And match response.afterLastStage == 'STOP'
    And match response.stages[*].stage == [1, 2, 3]

    # 3. Late piece on a PO line with the sequence
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66701', poLineNumber: '66701-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceId)', currentDate: '#(currentDate)', claimSequenceId: '#(seqId)' }

    # 4. 1st claim: stage 1 (MANUAL), stage interval instead of the request interval, no job
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 201
    * def result = resultOf(response, pieceId)
    And match result.status == 'success'
    And match result.deliveryType == 'MANUAL'
    And match result.transmissionMethod == '#notpresent'
    And match result.sequence == { id: '#(seqId)', stage: 1 }
    And match result.interval == 3
    * def v = call verifyPieceClaim { pieceId: '#(pieceId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqId)', stage: 1, interval: 3 }
    * def v = call getJobsOfConfig { configId: '#(configFileId)', expectedCount: 0 }
    * def v = call getJobsOfConfig { configId: '#(configFtpId)', expectedCount: 0 }

    # 5. 2nd claim: stage 2, only the File download config gets a job
    * def v = call expireClaim { pieceId: '#(pieceId)' }
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 201
    * def result = resultOf(response, pieceId)
    And match result.deliveryType == 'INTEGRATION'
    And match result.transmissionMethod == 'File download'
    And match result.sequence == { id: '#(seqId)', stage: 2 }
    And match result.interval == 5
    * def v = call verifyPieceClaim { pieceId: '#(pieceId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqId)', stage: 2, interval: 5 }
    * def fileJobs = call getJobsOfConfig { configId: '#(configFileId)', expectedCount: 1 }
    * match claimPieceIdsOf(fileJobs.jobs[0]) == ['#(pieceId)']
    * def v = call getJobsOfConfig { configId: '#(configFtpId)', expectedCount: 0 }

    # 6. 3rd claim: stage 3, only the FTP config gets a job
    * def v = call expireClaim { pieceId: '#(pieceId)' }
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 201
    * def result = resultOf(response, pieceId)
    And match result.deliveryType == 'INTEGRATION'
    And match result.transmissionMethod == 'FTP'
    And match result.sequence == { id: '#(seqId)', stage: 3 }
    And match result.interval == 7
    * def v = call verifyPieceClaim { pieceId: '#(pieceId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqId)', stage: 3, interval: 7 }
    * def v = call getJobsOfConfig { configId: '#(configFileId)', expectedCount: 1 }
    * def ftpJobs = call getJobsOfConfig { configId: '#(configFtpId)', expectedCount: 1 }
    * match claimPieceIdsOf(ftpJobs.jobs[0]) == ['#(pieceId)']

    # 7. 4th claim: sequence completed (STOP) → 400, nothing written, no job
    * def v = call expireClaim { pieceId: '#(pieceId)' }
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 400
    And match response.errors == '#[1]'
    And match response.errors[0].code == 'claimSequenceCompleted'
    And match response.errors[0].parameters contains only [{ key: 'pieceId', value: '#(pieceId)' }, { key: 'claimSequenceId', value: '#(seqId)' }]
    * def v = call verifyPieceClaim { pieceId: '#(pieceId)', receivingStatus: 'Late', claimSequenceId: '#(seqId)', stage: 3, interval: 7 }

    # 8. The completed piece blocks the whole request, also a claimable piece without sequence
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66702', poLineNumber: '66702-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(otherPieceId)', currentDate: '#(currentDate)' }
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)', '#(otherPieceId)'], claimingInterval: 1 }
    When method POST
    Then status 400
    And match errorCodesOf(response) == ['claimSequenceCompleted']
    Given path 'orders/pieces', otherPieceId
    When method GET
    Then status 200
    And match response.receivingStatus == 'Late'
    And match response.claim == '#notpresent'
    * def v = call getJobsOfConfig { configId: '#(configFileId)', expectedCount: 1 }
    * def v = call getJobsOfConfig { configId: '#(configFtpId)', expectedCount: 1 }


  @Positive
  Scenario: REPEAT_LAST repeats the last stage, manual stages need no Claims integration
    # 1. Vendor without any Claims config, manual-only sequence with REPEAT_LAST
    * def orgId = call uuid
    * def seqId = call uuid
    * def pieceId = call uuid
    * def v = call createOrganization { id: '#(orgId)', code: 'ORG_SEQ_REPEAT', name: 'ORG_SEQ_REPEAT', isVendor: true }
    * def stages = [{ name: '1st claim', deliveryType: 'MANUAL', interval: 2 }, { name: '2nd claim', deliveryType: 'MANUAL', interval: 4 }]
    * def v = call createClaimSequence { sequenceId: '#(seqId)', sequenceName: 'SEQ_REPEAT', stages: '#(stages)', afterLastStage: 'REPEAT_LAST' }
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66711', poLineNumber: '66711-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceId)', currentDate: '#(currentDate)', claimSequenceId: '#(seqId)' }

    # 2. Stage 1
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 201
    And match resultOf(response, pieceId).sequence == { id: '#(seqId)', stage: 1 }
    * def v = call verifyPieceClaim { pieceId: '#(pieceId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqId)', stage: 1, interval: 2 }

    # 3. Stage 2 (last)
    * def v = call expireClaim { pieceId: '#(pieceId)' }
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 201
    And match resultOf(response, pieceId).sequence == { id: '#(seqId)', stage: 2 }
    * def v = call verifyPieceClaim { pieceId: '#(pieceId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqId)', stage: 2, interval: 4 }

    # 4. After the last stage: stage 2 again with its interval
    * def v = call expireClaim { pieceId: '#(pieceId)' }
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 201
    * def result = resultOf(response, pieceId)
    And match result.deliveryType == 'MANUAL'
    And match result.sequence == { id: '#(seqId)', stage: 2 }
    And match result.interval == 4
    * def v = call verifyPieceClaim { pieceId: '#(pieceId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqId)', stage: 2, interval: 4 }


  @Positive
  Scenario: One request with a manual stage, an FTP stage and a piece without sequence
    # 1. Vendor with an FTP and a File download Claims config, both for every acquisition method
    * def orgId = call uuid
    * def configFileId = call uuid
    * def configFtpId = call uuid
    * def seqManualId = call uuid
    * def seqFtpId = call uuid
    * def pieceManualId = call uuid
    * def pieceFtpId = call uuid
    * def pieceNoSeqId = call uuid
    * def v = call createOrganization { id: '#(orgId)', code: 'ORG_SEQ_MIXED', name: 'ORG_SEQ_MIXED', isVendor: true }
    * table configs
      | configId     | configName        | vendorId | transmissionMethod | fileFormat | defaultAcquisitionMethods |
      | configFileId | "SEQ_MIXED_FILE"  | orgId    | "File download"    | "CSV"      | []                        |
      | configFtpId  | "SEQ_MIXED_FTP"   | orgId    | "FTP"              | "CSV"      | []                        |
    * def v = call createIntegrationDetails configs

    # 2. Two sequences: stage 1 manual / stage 1 FTP
    * def v = call createClaimSequence { sequenceId: '#(seqManualId)', sequenceName: 'SEQ_MIXED_MANUAL', stages: [{ name: 'phone', deliveryType: 'MANUAL', interval: 10 }] }
    * def v = call createClaimSequence { sequenceId: '#(seqFtpId)', sequenceName: 'SEQ_MIXED_FTP', stages: [{ name: 'ftp', deliveryType: 'INTEGRATION', transmissionMethod: 'FTP', interval: 12 }] }

    # 3. One Late piece per PO line: manual sequence, FTP sequence, no sequence
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66721', poLineNumber: '66721-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceManualId)', currentDate: '#(currentDate)', claimSequenceId: '#(seqManualId)' }
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66722', poLineNumber: '66722-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceFtpId)', currentDate: '#(currentDate)', claimSequenceId: '#(seqFtpId)' }
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66723', poLineNumber: '66723-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceNoSeqId)', currentDate: '#(currentDate)' }

    # 4. Claim all three in one request
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceManualId)', '#(pieceFtpId)', '#(pieceNoSeqId)'], claimingInterval: 1 }
    When method POST
    Then status 201
    * def manualResult = resultOf(response, pieceManualId)
    * def ftpResult = resultOf(response, pieceFtpId)
    * def noSeqResult = resultOf(response, pieceNoSeqId)
    And match manualResult contains { status: 'success', deliveryType: 'MANUAL', interval: 10 }
    And match manualResult.sequence == { id: '#(seqManualId)', stage: 1 }
    And match ftpResult contains { status: 'success', deliveryType: 'INTEGRATION', transmissionMethod: 'FTP', interval: 12 }
    And match ftpResult.sequence == { id: '#(seqFtpId)', stage: 1 }
    And match noSeqResult contains { status: 'success', deliveryType: 'INTEGRATION', interval: 1 }
    And match noSeqResult.transmissionMethod == '#notpresent'
    And match noSeqResult.sequence == '#notpresent'

    # 5. FTP config: the FTP-stage piece and the piece without sequence; File download: only the piece without sequence
    * def ftpJobs = call getJobsOfConfig { configId: '#(configFtpId)', expectedCount: 1 }
    * match claimPieceIdsOf(ftpJobs.jobs[0]) contains only ['#(pieceFtpId)', '#(pieceNoSeqId)']
    * def fileJobs = call getJobsOfConfig { configId: '#(configFileId)', expectedCount: 1 }
    * match claimPieceIdsOf(fileJobs.jobs[0]) == ['#(pieceNoSeqId)']

    # 6. Pieces
    * def v = call verifyPieceClaim { pieceId: '#(pieceManualId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqManualId)', stage: 1, interval: 10 }
    * def v = call verifyPieceClaim { pieceId: '#(pieceFtpId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqFtpId)', stage: 1, interval: 12 }
    Given path 'orders/pieces', pieceNoSeqId
    When method GET
    Then status 200
    And match response.receivingStatus == 'Claim sent'
    And match response.claim == '#notpresent'
    And match response.claimingInterval == 1


  @Negative
  Scenario: An integration stage without a Claims config for its transmission method fails without changing the piece
    # 1. Vendor with a File download config only, sequence whose stage 1 is FTP
    * def orgId = call uuid
    * def configFileId = call uuid
    * def seqId = call uuid
    * def pieceId = call uuid
    * def v = call createOrganization { id: '#(orgId)', code: 'ORG_SEQ_NO_FTP', name: 'ORG_SEQ_NO_FTP', isVendor: true }
    * def v = call createIntegrationDetails { configId: '#(configFileId)', configName: 'SEQ_NO_FTP_FILE', vendorId: '#(orgId)', transmissionMethod: 'File download', fileFormat: 'CSV', defaultAcquisitionMethods: [] }
    * def v = call createClaimSequence { sequenceId: '#(seqId)', sequenceName: 'SEQ_NO_FTP', stages: [{ name: 'ftp', deliveryType: 'INTEGRATION', transmissionMethod: 'FTP', interval: 5 }] }
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66731', poLineNumber: '66731-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceId)', currentDate: '#(currentDate)', claimSequenceId: '#(seqId)' }

    # 2. Claim → 422 before any write
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 422
    And match errorCodesOf(response) == ['claimSequenceStageRequiresIntegration']
    And match response.errors[0].parameters contains { key: 'vendorId', value: '#(orgId)' }
    And match response.errors[0].parameters contains { key: 'transmissionMethod', value: 'FTP' }
    And match response.errors[0].parameters contains { key: 'pieceId', value: '#(pieceId)' }

    # 3. Piece unchanged, no job
    Given path 'orders/pieces', pieceId
    When method GET
    Then status 200
    And match response.receivingStatus == 'Late'
    And match response.claim == '#notpresent'
    * def v = call getJobsOfConfig { configId: '#(configFileId)', expectedCount: 0 }


  @Negative
  Scenario: An inactive or unknown claim sequence rejects the whole request
    # 1. Vendor with a catch-all File download config, an inactive sequence and an id without sequence
    * def orgId = call uuid
    * def configFileId = call uuid
    * def seqInactiveId = call uuid
    * def seqUnknownId = call uuid
    * def pieceInactiveId = call uuid
    * def pieceUnknownId = call uuid
    * def pieceNoSeqId = call uuid
    * def v = call createOrganization { id: '#(orgId)', code: 'ORG_SEQ_INVALID', name: 'ORG_SEQ_INVALID', isVendor: true }
    * def v = call createIntegrationDetails { configId: '#(configFileId)', configName: 'SEQ_INVALID_FILE', vendorId: '#(orgId)', transmissionMethod: 'File download', fileFormat: 'CSV', defaultAcquisitionMethods: [] }
    * def v = call createClaimSequence { sequenceId: '#(seqInactiveId)', sequenceName: 'SEQ_INACTIVE', stages: [{ name: 'phone', deliveryType: 'MANUAL', interval: 5 }], isActive: false }
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66741', poLineNumber: '66741-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceInactiveId)', currentDate: '#(currentDate)', claimSequenceId: '#(seqInactiveId)' }
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66742', poLineNumber: '66742-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceUnknownId)', currentDate: '#(currentDate)', claimSequenceId: '#(seqUnknownId)' }
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66743', poLineNumber: '66743-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceNoSeqId)', currentDate: '#(currentDate)' }

    # 2. Inactive sequence → 400 claimSequenceInactive
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceInactiveId)'], claimingInterval: 1 }
    When method POST
    Then status 400
    And match errorCodesOf(response) == ['claimSequenceInactive']
    And match response.errors[0].parameters contains only [{ key: 'pieceId', value: '#(pieceInactiveId)' }, { key: 'claimSequenceId', value: '#(seqInactiveId)' }]

    # 3. Unknown sequence → 400 claimSequenceNotFound
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceUnknownId)'], claimingInterval: 1 }
    When method POST
    Then status 400
    And match errorCodesOf(response) == ['claimSequenceNotFound']
    And match response.errors[0].parameters contains only [{ key: 'pieceId', value: '#(pieceUnknownId)' }, { key: 'claimSequenceId', value: '#(seqUnknownId)' }]

    # 4. Together with a claimable piece: one error per invalid piece, nothing written, no job
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceInactiveId)', '#(pieceUnknownId)', '#(pieceNoSeqId)'], claimingInterval: 1 }
    When method POST
    Then status 400
    And match errorCodesOf(response) contains only ['claimSequenceInactive', 'claimSequenceNotFound']
    Given path 'orders/pieces'
    And param query = 'id==(' + pieceInactiveId + ' or ' + pieceUnknownId + ' or ' + pieceNoSeqId + ')'
    When method GET
    Then status 200
    And match response.totalRecords == 3
    And match each response.pieces contains { receivingStatus: 'Late' }
    And match karate.jsonPath(response, '$.pieces[*].claim') == []
    * def v = call getJobsOfConfig { configId: '#(configFileId)', expectedCount: 0 }


  @Positive
  Scenario: A PO line switched to another claim sequence restarts at stage 1
    # 1. Vendor without Claims config, two manual sequences
    * def orgId = call uuid
    * def seqFirstId = call uuid
    * def seqSecondId = call uuid
    * def pieceId = call uuid
    * def v = call createOrganization { id: '#(orgId)', code: 'ORG_SEQ_SWITCH', name: 'ORG_SEQ_SWITCH', isVendor: true }
    * def v = call createClaimSequence { sequenceId: '#(seqFirstId)', sequenceName: 'SEQ_SWITCH_FIRST', stages: [{ name: 'first 1', deliveryType: 'MANUAL', interval: 3 }, { name: 'first 2', deliveryType: 'MANUAL', interval: 4 }] }
    * def v = call createClaimSequence { sequenceId: '#(seqSecondId)', sequenceName: 'SEQ_SWITCH_SECOND', stages: [{ name: 'second 1', deliveryType: 'MANUAL', interval: 6 }, { name: 'second 2', deliveryType: 'MANUAL', interval: 8 }] }
    * def created = call createLatePiece { orgId: '#(orgId)', poNumber: '66751', poLineNumber: '66751-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceId)', currentDate: '#(currentDate)', claimSequenceId: '#(seqFirstId)' }

    # 2. Claim twice on the first sequence: stage 1, stage 2
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 201
    * def v = call expireClaim { pieceId: '#(pieceId)' }
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 201
    * def v = call verifyPieceClaim { pieceId: '#(pieceId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqFirstId)', stage: 2, interval: 4 }
    * def v = call expireClaim { pieceId: '#(pieceId)' }

    # 3. Switch the PO line to the second sequence
    Given path 'orders/order-lines', created.poLineId
    When method GET
    Then status 200
    * def poLine = response
    * set poLine.claimSequenceId = seqSecondId
    Given path 'orders/order-lines', created.poLineId
    And request poLine
    When method PUT
    Then status 204

    # 4. Next claim starts at stage 1 of the second sequence
    Given path 'pieces/claim'
    And request { claimingPieceIds: ['#(pieceId)'], claimingInterval: 1 }
    When method POST
    Then status 201
    And match resultOf(response, pieceId).sequence == { id: '#(seqSecondId)', stage: 1 }
    * def v = call verifyPieceClaim { pieceId: '#(pieceId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqSecondId)', stage: 1, interval: 6 }


  @Positive
  Scenario: Batch status Claim sent applies manual stages and rejects integration stages and completed sequences
    # 1. Vendor with a File download config, a manual one-stage sequence (STOP) and a File download one-stage sequence
    * def orgId = call uuid
    * def configFileId = call uuid
    * def seqManualId = call uuid
    * def seqFileId = call uuid
    * def pieceManualId = call uuid
    * def pieceFileId = call uuid
    * def v = call createOrganization { id: '#(orgId)', code: 'ORG_SEQ_BATCH', name: 'ORG_SEQ_BATCH', isVendor: true }
    * def v = call createIntegrationDetails { configId: '#(configFileId)', configName: 'SEQ_BATCH_FILE', vendorId: '#(orgId)', transmissionMethod: 'File download', fileFormat: 'CSV', defaultAcquisitionMethods: [] }
    * def v = call createClaimSequence { sequenceId: '#(seqManualId)', sequenceName: 'SEQ_BATCH_MANUAL', stages: [{ name: 'phone', deliveryType: 'MANUAL', interval: 9 }] }
    * def v = call createClaimSequence { sequenceId: '#(seqFileId)', sequenceName: 'SEQ_BATCH_FILE', stages: [{ name: 'file', deliveryType: 'INTEGRATION', transmissionMethod: 'File download', interval: 5 }] }
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66761', poLineNumber: '66761-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceManualId)', currentDate: '#(currentDate)', claimSequenceId: '#(seqManualId)' }
    * def v = call createLatePiece { orgId: '#(orgId)', poNumber: '66762', poLineNumber: '66762-1', acqMethodId: '#(globalApprovalPlanAcqMethodId)', pieceId: '#(pieceFileId)', currentDate: '#(currentDate)', claimSequenceId: '#(seqFileId)' }

    # 2. Manual stage: batch status sets stage 1 and its interval, no job
    * def v = call updatePiecesBatchStatus { pieceIds: ['#(pieceManualId)'], receivingStatus: 'Claim sent' }
    * def v = call verifyPieceClaim { pieceId: '#(pieceManualId)', receivingStatus: 'Claim sent', claimSequenceId: '#(seqManualId)', stage: 1, interval: 9 }

    # 3. Last stage passed (STOP): batch status → 400 claimSequenceCompleted, piece stays Late
    * def v = call expireClaim { pieceId: '#(pieceManualId)' }
    Given path 'orders/pieces-batch/status'
    And request { pieceIds: ['#(pieceManualId)'], receivingStatus: 'Claim sent' }
    When method PUT
    Then status 400
    And match errorCodesOf(response) == ['claimSequenceCompleted']
    * def v = call verifyPieceClaim { pieceId: '#(pieceManualId)', receivingStatus: 'Late', claimSequenceId: '#(seqManualId)', stage: 1, interval: 9 }

    # 4. Integration stage: batch status never sends a claim → 422, piece unchanged
    Given path 'orders/pieces-batch/status'
    And request { pieceIds: ['#(pieceFileId)'], receivingStatus: 'Claim sent' }
    When method PUT
    Then status 422
    And match errorCodesOf(response) == ['claimSequenceStageRequiresIntegration']
    And match response.errors[0].parameters contains { key: 'transmissionMethod', value: 'File download' }
    And match response.errors[0].parameters contains { key: 'pieceId', value: '#(pieceFileId)' }
    Given path 'orders/pieces', pieceFileId
    When method GET
    Then status 200
    And match response.receivingStatus == 'Late'
    And match response.claim == '#notpresent'
    * def v = call getJobsOfConfig { configId: '#(configFileId)', expectedCount: 0 }
